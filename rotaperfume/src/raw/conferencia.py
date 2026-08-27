# Databricks notebook source
# MAGIC %md
# MAGIC # Conferencia de chegada do raw
# MAGIC
# MAGIC A tarefa mais chata do pipeline e a que mais salva emprego.
# MAGIC
# MAGIC Arquivo que nao chega **nao da erro**: ele da numero menor, e o dashboard
# MAGIC mostra metade da receita com cara de numero certo. Esta tarefa transforma
# MAGIC esse silencio em falha barulhenta -- se faltar arquivo ou algum vier
# MAGIC vazio, o job para aqui e nada a jusante roda com dado pela metade.

# COMMAND ----------

from datetime import datetime, timezone

dbutils.widgets.text("catalog", "lakehouse_rotaperfume", "Catalogo")
catalog = dbutils.widgets.get("catalog")

VOLUME = f"/Volumes/{catalog}/bronze/raw"

# Os 10 arquivos que TEM que estar la. A lista e' explicita de proposito:
# e' ela que sabe o que "completo" significa.
ESPERADOS = {
    "erp": ["produtos", "pedidos", "itens_pedido", "pagamentos", "estoque"],
    "crm": ["clientes", "vendedores", "carteira", "oportunidades", "visitas"],
}

print(f"catalogo: {catalog}")
print(f"volume:   {VOLUME}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1. O que chegou no Volume

# COMMAND ----------

def listar(sistema: str) -> dict[str, int]:
    """Nome do arquivo -> tamanho em bytes, para um sistema de origem."""
    try:
        return {f.name: f.size for f in dbutils.fs.ls(f"{VOLUME}/{sistema}")}
    except Exception:
        # pasta inexistente conta como "nada chegou" -- o diagnostico vem abaixo
        return {}


chegaram = {sistema: listar(sistema) for sistema in ESPERADOS}

for sistema, arquivos in chegaram.items():
    print(f"{sistema}: {len(arquivos)} arquivo(s)")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 2. Conferencia: existe, e tem conteudo?

# COMMAND ----------

problemas: list[str] = []
linhas_controle = []
conferido_em = datetime.now(timezone.utc)

for sistema, datasets in ESPERADOS.items():
    for dataset in datasets:
        arquivo = f"{dataset}.csv"
        bytes_ = chegaram[sistema].get(arquivo)

        if bytes_ is None:
            problemas.append(f"{sistema}/{arquivo}: NAO CHEGOU")
            continue
        if bytes_ == 0:
            problemas.append(f"{sistema}/{arquivo}: chegou VAZIO (0 bytes)")
            continue

        caminho = f"{VOLUME}/{sistema}/{arquivo}"
        linhas = (
            spark.read.option("header", True).csv(caminho).count()
        )
        if linhas == 0:
            problemas.append(f"{sistema}/{arquivo}: sem nenhuma linha de dado")
            continue

        linhas_controle.append((sistema, arquivo, int(bytes_), int(linhas), conferido_em))

# arquivo que ninguem esperava tambem e' sinal de que algo mudou na origem
for sistema, arquivos in chegaram.items():
    inesperados = set(arquivos) - {f"{d}.csv" for d in ESPERADOS[sistema]}
    for arquivo in sorted(inesperados):
        print(f"AVISO: {sistema}/{arquivo} chegou mas nao estava na lista de esperados")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 3. A tabela de controle
# MAGIC
# MAGIC Gravada ANTES de levantar a excecao: mesmo num run que falha, fica
# MAGIC registrado o que chegou -- e o que faltava fica evidente pela ausencia.

# COMMAND ----------

COLUNAS = ["sistema", "arquivo", "bytes", "linhas", "conferido_em"]
TABELA = f"{catalog}.bronze._raw_arquivos"

if linhas_controle:
    (
        spark.createDataFrame(linhas_controle, COLUNAS)
        .write.mode("overwrite")
        .option("overwriteSchema", "true")
        .saveAsTable(TABELA)
    )

    spark.sql(
        f"COMMENT ON TABLE {TABELA} IS "
        "'Controle de chegada do raw: um registro por arquivo conferido no Volume "
        "bronze.raw, com tamanho, contagem de linhas de dado e horario da conferencia.'"
    )

# COMMAND ----------

# MAGIC %md
# MAGIC ## 4. O relatorio

# COMMAND ----------

largura = max((len(a) for _, a, *_ in linhas_controle), default=10)
print(f"{'SISTEMA':<8} {'ARQUIVO':<{largura}} {'BYTES':>12} {'LINHAS':>10}")
print("-" * (8 + largura + 26))
for sistema, arquivo, bytes_, linhas, _ in sorted(linhas_controle, key=lambda r: -r[3]):
    print(f"{sistema:<8} {arquivo:<{largura}} {bytes_:>12,} {linhas:>10,}")
print("-" * (8 + largura + 26))

total_arquivos = len(linhas_controle)
total_linhas = sum(r[3] for r in linhas_controle)
total_mb = sum(r[2] for r in linhas_controle) / 1024 / 1024
esperado_arquivos = sum(len(v) for v in ESPERADOS.values())

print(f"{total_arquivos} de {esperado_arquivos} arquivos | "
      f"{total_linhas:,} linhas de dado | {total_mb:.1f} MB")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 5. Falhar alto, se for o caso

# COMMAND ----------

if problemas:
    detalhe = "\n  - ".join(problemas)
    raise Exception(
        f"Conferencia de chegada FALHOU: {len(problemas)} problema(s) no raw.\n"
        f"  - {detalhe}\n\n"
        f"O pipeline para aqui de proposito. Rode 'bash scripts/subir-raw.sh <profile>' "
        f"e execute o job de novo."
    )

print("conferencia OK: os 10 arquivos chegaram e tem conteudo.")
