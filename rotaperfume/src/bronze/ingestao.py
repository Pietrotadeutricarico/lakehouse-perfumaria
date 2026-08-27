# Databricks notebook source
# MAGIC %md
# MAGIC # Bronze: o arquivo vira tabela
# MAGIC
# MAGIC Dez tabelas, **uma** funcao e **uma** lista. Se amanha o ERP mandar a
# MAGIC decima primeira, e' uma linha.
# MAGIC
# MAGIC ## A regra da bronze: nao conserta nada
# MAGIC
# MAGIC Tudo entra como **texto**, de proposito. `inferSchema=False` nao e'
# MAGIC preguica, e' decisao: se o Spark adivinhar o tipo, o CNPJ vira numero e
# MAGIC perde o zero da frente em 309 clientes, e `15/10/2025` vira nulo -- sem
# MAGIC erro nenhum, sem ninguem ficar sabendo.
# MAGIC
# MAGIC A sujeira e' preservada porque ela e' a PROVA de que o problema veio da
# MAGIC origem, e nao da nossa limpeza. Converter e' trabalho da silver.

# COMMAND ----------

from pyspark.sql import functions as F

dbutils.widgets.text("catalog", "lakehouse_rotaperfume", "Catalogo")
catalog = dbutils.widgets.get("catalog")

VOLUME = f"/Volumes/{catalog}/bronze/raw"

# Mesma lista da conferencia de chegada: e' ela que sabe o que "completo" significa.
ORIGENS = {
    "erp": ["produtos", "pedidos", "itens_pedido", "pagamentos", "estoque"],
    "crm": ["clientes", "vendedores", "carteira", "oportunidades", "visitas"],
}

DESCRICAO = {
    "erp": "ERP (faturamento e estoque)",
    "crm": "CRM (relacionamento comercial)",
}

print(f"catalogo: {catalog}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## A funcao de ingestao -- escrita uma vez

# COMMAND ----------

def ingerir(sistema: str, tabela: str) -> int:
    """Le um CSV do Volume e grava a tabela Delta correspondente na bronze.

    Nenhuma limpeza, nenhuma conversao de tipo. Devolve a contagem gravada.
    """
    caminho = f"{VOLUME}/{sistema}/{tabela}.csv"
    destino = f"{catalog}.bronze.{tabela}"

    df = (
        spark.read
        # header sim; inferencia de tipo NAO -- toda coluna de negocio nasce string
        .option("header", True)
        .option("inferSchema", False)
        # os arquivos sao CRLF e nao tem aspas nem quebra de linha dentro de campo,
        # entao multiLine fica desligado (ligado, ele muda a contagem sem avisar).
        .csv(caminho)
        # Leitor CSV comum de proposito: `read_files` inventa a coluna _rescued_data,
        # e `rescuedDataColumn => ''` nao desliga -- cria uma coluna de nome vazio
        # que quebra o CREATE TABLE. Mais simples evitar a origem do problema.
    )

    # As DUAS unicas colunas que a bronze acrescenta. Elas respondem as duas
    # primeiras perguntas de qualquer investigacao: quando entrou, e de onde veio.
    df = (
        df.withColumn("_ingerido_em", F.current_timestamp())
          .withColumn("_arquivo_origem", F.col("_metadata.file_path"))
    )

    df.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(destino)

    spark.sql(
        f"COMMENT ON TABLE {destino} IS "
        f"'Bronze: {tabela} como veio do {DESCRICAO[sistema]}, sem limpeza nem "
        f"conversao de tipo. Origem: {sistema}/{tabela}.csv.'"
    )

    return spark.table(destino).count()

# COMMAND ----------

# MAGIC %md
# MAGIC ## Uma lista, dez tabelas

# COMMAND ----------

ingeridas: list[tuple[str, str, int]] = []

for sistema, tabelas in ORIGENS.items():
    for tabela in tabelas:
        linhas = ingerir(sistema, tabela)
        ingeridas.append((sistema, tabela, linhas))
        print(f"  {sistema}/{tabela:<14} {linhas:>10,} linhas")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Conferencia: a tabela bate com o arquivo de origem?
# MAGIC
# MAGIC `bronze._raw_arquivos.linhas` **ja** e' linha de dado -- o header foi
# MAGIC excluido na entrega 1, na leitura com `header=True`. Entao a comparacao
# MAGIC certa e' direta: linhas da tabela == linhas registradas. Subtrair o
# MAGIC header de novo aqui daria -1 em cada uma das dez.

# COMMAND ----------

no_arquivo = {
    r["arquivo"]: r["linhas"]
    for r in spark.table(f"{catalog}.bronze._raw_arquivos").collect()
}

divergentes = []
print(f"{'SISTEMA':<8} {'TABELA':<15} {'NA TABELA':>11} {'NO ARQUIVO':>11}  BATE")
print("-" * 56)
for sistema, tabela, linhas in sorted(ingeridas, key=lambda r: -r[2]):
    esperado = no_arquivo.get(f"{tabela}.csv")
    bate = linhas == esperado
    if not bate:
        divergentes.append(f"{tabela}: tabela={linhas:,} arquivo={esperado:,}")
    print(f"{sistema:<8} {tabela:<15} {linhas:>11,} {esperado:>11,}  {'ok' if bate else 'NAO'}")
print("-" * 56)
print(f"{len(ingeridas)} tabelas | {sum(r[2] for r in ingeridas):,} linhas")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Falhar alto, se for o caso

# COMMAND ----------

if divergentes:
    detalhe = "\n  - ".join(divergentes)
    raise Exception(
        f"Ingestao da bronze DIVERGIU do raw em {len(divergentes)} tabela(s):\n"
        f"  - {detalhe}\n\n"
        "Quando a contagem nao bate, quase sempre o CSV foi lido errado -- "
        "multiLine ligado ou separador trocado. Melhor descobrir agora."
    )

print(f"bronze OK: {len(ingeridas)} tabelas, {sum(r[2] for r in ingeridas):,} linhas, "
      "batendo com o raw.")
