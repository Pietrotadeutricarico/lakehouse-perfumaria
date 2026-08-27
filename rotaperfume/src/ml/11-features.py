# Databricks notebook source
# MAGIC %md
# MAGIC # Features: o que descreve um cliente
# MAGIC
# MAGIC A gold responde tudo sobre o passado. O diretor nao perguntou sobre o
# MAGIC passado -- ele perguntou **quais 200 clientes ligar esta semana**.
# MAGIC
# MAGIC Modelo nao come tabela fato: come **uma linha por cliente**, com tudo
# MAGIC que se sabia dele ate uma data de corte.
# MAGIC
# MAGIC ## A data de corte e a espinha deste arquivo
# MAGIC
# MAGIC Toda fonte e filtrada pela data dela na PRIMEIRA linha da leitura, sem
# MAGIC excecao. Nao e' disciplina pessoal, e' assinatura de funcao: a data
# MAGIC entra por parametro e sai gravada numa coluna da tabela.
# MAGIC
# MAGIC ## Uma funcao, dois usos
# MAGIC
# MAGIC A MESMA `montar_features()` gera o dado de treino (com rotulo) e o de
# MAGIC score (sem rotulo). E' impossivel os dois divergirem -- esse desencontro
# MAGIC tem nome, *training/serving skew*, e e' o que o Feature Store resolve
# MAGIC com infraestrutura. Aqui esta resolvido com um `def`.

# COMMAND ----------

from pyspark.sql import functions as F, Window


def _sem_zero(coluna):
    """Devolve a coluna, ou NULL quando ela e' zero -- para nao dividir por zero.

    Equivale a NULLIF(coluna, 0). Escrito a mao de proposito: F.nullif so'
    existe em versoes recentes do PySpark, e este notebook roda em serverless.
    """
    return F.when(coluna != 0, coluna)

dbutils.widgets.text("catalog", "lakehouse_rotaperfume", "Catalogo")
catalog = dbutils.widgets.get("catalog")

# O "hoje" deste dataset e' 2026-08-31. Nada de current_date() em lugar nenhum:
# a base terminaria mudando de tamanho conforme o dia em que o job roda.
REFERENCIA_SCORE = "2026-08-31"
REFERENCIA_TREINO = "2026-08-01"
JANELA_ALVO_DIAS = 7      # a fila e' semanal, entao o rotulo e' semanal

print(f"catalogo: {catalog}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## A funcao
# MAGIC
# MAGIC **`gold.dim_cliente` NAO e' lida aqui.** `dias_sem_comprar`,
# MAGIC `receita_acumulada` e `total_pedidos` agregam a base INTEIRA, sem corte.
# MAGIC Usar qualquer uma delas seria olhar o futuro -- vazamento. Ela so' entra
# MAGIC mais tarde, para nome e cidade.

# COMMAND ----------

def montar_features(referencia: str):
    """Uma linha por cliente com tudo que se sabia dele ATE `referencia`.

    `referencia` e' uma data ISO (YYYY-MM-DD). Toda fonte e' cortada por ela.
    """
    corte = F.lit(referencia).cast("date")

    # ---------------------------------------------------------------- fontes
    # O filtro vem na primeira linha de cada leitura. Se ele descer para
    # depois de uma agregacao, o vazamento entra sem avisar.
    vendas = (
        spark.table(f"{catalog}.gold.fato_vendas")
        .where(F.col("data_pedido") < corte)
    )
    oportunidades = (
        spark.table(f"{catalog}.silver.oportunidades")
        .where(F.col("data_abertura") < corte)
    )
    visitas = (
        spark.table(f"{catalog}.silver.visitas")
        .where(F.col("data_visita") < corte)
    )

    # ------------------------------------------------------------------ RFM
    # cast("double") em TODA feature numerica: receita e margem saem da gold
    # como DECIMAL(18,2), e o registro do modelo quebra depois com
    # "Object of type Decimal is not JSON serializable".
    rfm = vendas.groupBy("cliente_id").agg(
        F.datediff(corte, F.max("data_pedido")).cast("double").alias("recencia_dias"),
        F.countDistinct("pedido_id").cast("double").alias("frequencia_pedidos"),
        F.sum("receita").cast("double").alias("valor_total"),
        F.sum("margem").cast("double").alias("margem_total"),
    ).withColumn(
        "ticket_medio",
        (F.col("valor_total") / _sem_zero(F.col("frequencia_pedidos"))).cast("double"),
    ).withColumn(
        "margem_percentual",
        (F.col("margem_total") / _sem_zero(F.col("valor_total"))).cast("double"),
    )

    # ---------------------------------------------------------------- ritmo
    # Os gaps sao calculados UMA vez, com lag() sobre as datas DISTINTAS de
    # pedido -- media e desvio saem dai. Calcular duas vezes convida as duas
    # metricas a discordarem.
    datas = vendas.select("cliente_id", "data_pedido").distinct()
    janela = Window.partitionBy("cliente_id").orderBy("data_pedido")
    gaps = (
        datas
        .withColumn("anterior", F.lag("data_pedido").over(janela))
        .where(F.col("anterior").isNotNull())
        .select("cliente_id", F.datediff("data_pedido", "anterior").alias("gap"))
    )
    ritmo = gaps.groupBy("cliente_id").agg(
        F.avg("gap").cast("double").alias("intervalo_medio_dias"),
        F.stddev("gap").cast("double").alias("desvio_intervalo_dias"),
    )

    pedidos_90d = (
        vendas
        .where(F.col("data_pedido") >= F.date_sub(corte, 90))
        .groupBy("cliente_id")
        .agg(F.countDistinct("pedido_id").cast("double").alias("pedidos_ultimos_90d"))
    )

    # ------------------------------------------------------------------ CRM
    crm = oportunidades.groupBy("cliente_id").agg(
        F.sum(F.when(~F.col("ganha") & ~F.col("perdida"), 1).otherwise(0))
            .cast("double").alias("oportunidades_abertas"),
        F.sum(F.when(F.col("ganha"), 1).otherwise(0))
            .cast("double").alias("oportunidades_ganhas"),
        F.count("*").cast("double").alias("_oportunidades_total"),
    ).withColumn(
        "taxa_ganho",
        (F.col("oportunidades_ganhas") / _sem_zero(F.col("_oportunidades_total")))
            .cast("double"),
    ).drop("_oportunidades_total")

    visitas_agg = (
        visitas
        .groupBy("cliente_id")
        .agg(
            F.sum(F.when(F.col("data_visita") >= F.date_sub(corte, 90), 1).otherwise(0))
                .cast("double").alias("visitas_90d"),
            F.count("*").cast("double").alias("_visitas_total"),
            F.sum(F.when(F.col("gerou_pedido"), 1).otherwise(0))
                .cast("double").alias("_visitas_com_pedido"),
        )
        .withColumn(
            "conversao_visita",
            (F.col("_visitas_com_pedido") / _sem_zero(F.col("_visitas_total")))
                .cast("double"),
        )
        .drop("_visitas_total", "_visitas_com_pedido")
    )

    # ------------------------------------------------------------------ mix
    mix = vendas.groupBy("cliente_id").agg(
        F.countDistinct("sku").cast("double").alias("skus_distintos"),
        F.countDistinct("categoria").cast("double").alias("categorias_distintas"),
        F.countDistinct("marca").cast("double").alias("marcas_distintas"),
    )

    # concentracao na marca top: quanto da receita do cliente vem da marca que
    # ele mais compra. Perto de 1 significa dependencia de uma marca so'.
    por_marca = vendas.groupBy("cliente_id", "marca").agg(
        F.sum("receita").cast("double").alias("receita_marca")
    )
    marca_top = por_marca.groupBy("cliente_id").agg(
        F.max("receita_marca").alias("_receita_marca_top")
    )

    # o unico join necessario: data_lancamento vive em dim_produto
    lancamentos = (
        spark.table(f"{catalog}.gold.dim_produto")
        .where(
            F.col("data_lancamento").isNotNull()
            & (F.col("data_lancamento") >= F.date_sub(corte, 120))
            & (F.col("data_lancamento") < corte)
        )
        .select("sku")
    )
    comprou_lancamento = (
        vendas.join(lancamentos, "sku", "inner")
        .groupBy("cliente_id")
        .agg(F.lit(1.0).alias("comprou_lancamento"))
    )

    # ------------------------------------------------------------- montagem
    df = (
        rfm
        .join(ritmo, "cliente_id", "left")
        .join(pedidos_90d, "cliente_id", "left")
        .join(crm, "cliente_id", "left")
        .join(visitas_agg, "cliente_id", "left")
        .join(mix, "cliente_id", "left")
        .join(marca_top, "cliente_id", "left")
        .join(comprou_lancamento, "cliente_id", "left")
    )

    df = df.withColumn(
        "concentracao_marca_top",
        (F.col("_receita_marca_top") / _sem_zero(F.col("valor_total"))).cast("double"),
    ).drop("_receita_marca_top")

    # ARMADILHA 1, medida: F.least() IGNORA nulo e devolve o outro valor. Com
    # least(atraso, 10), os 80 clientes de UM pedido so' -- que tem
    # intervalo_medio_dias NULO -- receberiam 10 e iriam para o TOPO da fila.
    # Exatamente os clientes sobre os quais menos se sabe.
    intervalo = F.col("intervalo_medio_dias")
    df = df.withColumn(
        "atraso_relativo",
        F.when(
            intervalo.isNotNull() & (intervalo > 0),
            F.least(F.col("recencia_dias") / intervalo, F.lit(10.0)),
        ).cast("double"),
    )

    # Cliente sem oportunidade (sao 498) ou sem visita fica com 0, nao com
    # NULL: ausencia de oportunidade E' informacao, e NULL faria o modelo
    # perder quase um quinto da base. So' as features de RITMO podem ser
    # nulas, porque para quem tem um pedido so' o intervalo nao existe.
    zerar = [
        "pedidos_ultimos_90d", "oportunidades_abertas", "oportunidades_ganhas",
        "taxa_ganho", "visitas_90d", "conversao_visita",
        "skus_distintos", "categorias_distintas", "marcas_distintas",
        "concentracao_marca_top", "comprou_lancamento",
    ]
    df = df.fillna({c: 0.0 for c in zerar})

    # a data de corte nao e' comentario no codigo: e' coluna na tabela
    return df.withColumn("_referencia", corte)

# COMMAND ----------

# MAGIC %md
# MAGIC ## `gold.features_treino` -- com rotulo
# MAGIC
# MAGIC A janela do rotulo e' de sete dias porque a fila e' semanal. O rotulo
# MAGIC tem que ter o mesmo horizonte da decisao: o time liga para 200 por
# MAGIC semana, entao a pergunta e' "compra NESTA semana", nao "compra em algum
# MAGIC momento do mes".

# COMMAND ----------

treino = montar_features(REFERENCIA_TREINO)

fim_janela = F.date_add(F.lit(REFERENCIA_TREINO).cast("date"), JANELA_ALVO_DIAS - 1)
compradores = (
    spark.table(f"{catalog}.gold.fato_vendas")
    .where(
        (F.col("data_pedido") >= F.lit(REFERENCIA_TREINO).cast("date"))
        & (F.col("data_pedido") <= fim_janela)
    )
    .select("cliente_id").distinct()
    .withColumn("comprou_em_7d", F.lit(1))
)

treino = (
    treino.join(compradores, "cliente_id", "left")
    .fillna({"comprou_em_7d": 0})
)

TAB_TREINO = f"{catalog}.gold.features_treino"
treino.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(TAB_TREINO)

# saveAsTable NAO grava comment de tabela -- tem que vir em seguida.
spark.sql(
    f"COMMENT ON TABLE {TAB_TREINO} IS "
    "'Features de cliente para treino, com corte em 2026-08-01 e o alvo comprou_em_7d "
    "(pedido entre 2026-08-01 e 2026-08-07). Uma linha por cliente. Toda feature usa "
    "apenas dado anterior ao corte: nenhuma vem de dim_cliente, que agrega a base inteira.'"
)
print(f"{TAB_TREINO}: {treino.count():,} clientes")

# COMMAND ----------

# MAGIC %md
# MAGIC ## `gold.features_cliente` -- sem rotulo, e' o que sera pontuado

# COMMAND ----------

score = montar_features(REFERENCIA_SCORE)

TAB_SCORE = f"{catalog}.gold.features_cliente"
score.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(TAB_SCORE)

spark.sql(
    f"COMMENT ON TABLE {TAB_SCORE} IS "
    "'Features de cliente para pontuacao, com corte em 2026-08-31 e sem alvo. Gerada pela "
    "MESMA funcao que features_treino, com outra data -- e o que impede treino e score de "
    "divergirem (training/serving skew).'"
)
print(f"{TAB_SCORE}: {score.count():,} clientes")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Conferencia
# MAGIC
# MAGIC Recencia negativa e' a assinatura do vazamento: significa que alguem
# MAGIC comprou DEPOIS do corte e isso atravessou o filtro.

# COMMAND ----------

problemas = []

n_treino, n_score = treino.count(), score.count()
print(f"{'TABELA':<20} {'CLIENTES':>10}  CORTE")
print("-" * 46)
print(f"{'features_treino':<20} {n_treino:>10,}  {REFERENCIA_TREINO}")
print(f"{'features_cliente':<20} {n_score:>10,}  {REFERENCIA_SCORE}")

menor_recencia = treino.agg(F.min("recencia_dias")).first()[0]
print(f"\nmenor recencia no treino: {menor_recencia}")
if menor_recencia is not None and menor_recencia < 0:
    problemas.append(
        f"VAZAMENTO: recencia minima {menor_recencia} e' negativa -- uma fonte escapou do corte"
    )

compraram = treino.agg(F.sum("comprou_em_7d")).first()[0]
taxa = 100.0 * compraram / n_treino
print(f"taxa base: {compraram} de {n_treino} = {taxa:.2f}%")
print(f"-> {round(taxa * 2)} de cada 200 ligacoes as cegas viram pedido")

# o teto do atraso nao pode ser dominado por quem tem um pedido so'
no_teto = treino.where(F.col("atraso_relativo") >= 10.0).count()
sem_ritmo = treino.where(F.col("intervalo_medio_dias").isNull()).count()
print(f"\nclientes sem intervalo (um pedido so'): {sem_ritmo}")
print(f"clientes no teto do atraso_relativo   : {no_teto}")
if treino.where(F.col("intervalo_medio_dias").isNull() & F.col("atraso_relativo").isNotNull()).count():
    problemas.append(
        "Cliente sem intervalo recebeu atraso_relativo -- F.least() ignorou o nulo"
    )

# COMMAND ----------

if problemas:
    detalhe = "\n  - ".join(problemas)
    raise Exception(f"Features com problema:\n  - {detalhe}")

print("features OK: as duas tabelas nasceram do mesmo codigo, com cortes declarados.")
