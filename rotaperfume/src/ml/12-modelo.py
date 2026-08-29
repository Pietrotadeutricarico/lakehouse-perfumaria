# Databricks notebook source
# MAGIC %md
# MAGIC # O modelo, e a regua que ele precisa ganhar
# MAGIC
# MAGIC O `.fit()` e' igual para todo mundo. O que separa o projeto que funciona
# MAGIC do que impressiona no notebook e morre em producao e' outra coisa:
# MAGIC **provar que o modelo ganha do que a empresa ja faz de graca**.
# MAGIC
# MAGIC Por isso o baseline vem ANTES do treino neste arquivo. "AUC 0,87" nao
# MAGIC quer dizer nada sozinho. "Ganha da regua" quer dizer tudo.
# MAGIC
# MAGIC ## O teste que desconfia do sucesso
# MAGIC
# MAGIC Ha um `assert auc < 0.99` aqui embaixo. Vazamento de dado e' o unico
# MAGIC erro de ML que chega com elogio em vez de erro -- ninguem desconfia de
# MAGIC um resultado bom. A defesa nao e' atencao, e' um teste que **quebra o
# MAGIC job quando o resultado fica bom demais**.

# COMMAND ----------

import mlflow
from mlflow.tracking import MlflowClient
import numpy as np
import pandas as pd
from databricks.sdk import WorkspaceClient
from pyspark.sql import functions as F, Window
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.inspection import permutation_importance
from sklearn.metrics import roc_auc_score
from sklearn.model_selection import StratifiedKFold, cross_val_predict, train_test_split

dbutils.widgets.text("catalog", "lakehouse_rotaperfume", "Catalogo")
catalog = dbutils.widgets.get("catalog")

ALVO = "comprou_em_7d"
NAO_FEATURES = ["cliente_id", "_referencia", ALVO]
SEMENTE = 42
TAMANHO_FILA = 200          # o time liga para 200 por semana
MODELO_UC = f"{catalog}.gold.propensao_compra"

print(f"catalogo: {catalog}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1. O baseline -- antes de treinar qualquer coisa
# MAGIC
# MAGIC As duas respostas que qualquer sala comercial da: *"ligue para quem
# MAGIC parou de comprar"* e *"ligue para quem compra mais"*. Mais a coluna que
# MAGIC inventamos no prompt anterior, `atraso_relativo`.
# MAGIC
# MAGIC Cada uma usada como se fosse o score do modelo, medida no mesmo holdout.

# COMMAND ----------

treino_pdf = spark.table(f"{catalog}.gold.features_treino").toPandas()
FEATURES = [c for c in treino_pdf.columns if c not in NAO_FEATURES]

X = treino_pdf[FEATURES]
y = treino_pdf[ALVO].astype(int)

X_tr, X_ho, y_tr, y_ho = train_test_split(
    X, y, test_size=0.25, random_state=SEMENTE, stratify=y
)

taxa_base = float(y.mean())
print(f"{len(treino_pdf):,} clientes | {len(FEATURES)} features | "
      f"taxa base {100 * taxa_base:.2f}%")
print(f"holdout: {len(X_ho):,} clientes\n")

# roc_auc_score nao aceita NaN, e atraso_relativo e' nulo para quem tem um
# pedido so'. Zero e' o valor certo aqui: quem nao tem ritmo nao esta atrasado.
baselines = {
    "ligue para quem comprou recentemente": -X_ho["recencia_dias"],
    "jogar uma moeda": pd.Series(np.full(len(X_ho), 0.5), index=X_ho.index),
    "ligue para quem compra mais": X_ho["valor_total"],
    "ligue para quem esta atrasado": X_ho["atraso_relativo"].fillna(0),
}

auc_baseline = {}
print(f"{'A RESPOSTA':<40} {'AUC':>8}")
print("-" * 49)
for nome, score in baselines.items():
    # nome proprio: `auc` mais abaixo e' o do MODELO, e sombrear os dois
    # convida um bug silencioso na proxima edicao deste arquivo.
    auc_b = 0.5 if nome == "jogar uma moeda" else roc_auc_score(y_ho, score)
    auc_baseline[nome] = auc_b
    print(f"{nome:<40} {auc_b:>8.4f}")

# a regua do teste 1 e' o MELHOR baseline, nao um qualquer
melhor_nome = max(
    (n for n in auc_baseline if n != "jogar uma moeda"), key=auc_baseline.get
)
melhor_baseline = auc_baseline[melhor_nome]
print("-" * 49)
print(f"melhor baseline: {melhor_nome} ({melhor_baseline:.4f})")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 2. Treino
# MAGIC
# MAGIC `HistGradientBoostingClassifier` trata NaN nativamente, entao **nao
# MAGIC imputamos nada**: as features de ritmo sao nulas de proposito para quem
# MAGIC tem um pedido so', e imputar apagaria essa informacao.
# MAGIC
# MAGIC Nao usar XGBoost: ele treina e registra, mas falha ao CARREGAR de volta
# MAGIC no serverless por conflito com scikit-learn 1.6.1 (`__sklearn_tags__`),
# MAGIC e o erro so' aparece uma tarefa depois.

# COMMAND ----------

PARAMS = dict(random_state=SEMENTE, max_iter=200, learning_rate=0.05, max_depth=6)

modelo = HistGradientBoostingClassifier(**PARAMS)
modelo.fit(X_tr, y_tr)

auc = float(roc_auc_score(y_ho, modelo.predict_proba(X_ho)[:, 1]))
print(f"AUC do modelo no holdout: {auc:.4f}")
print(f"ganho sobre o melhor baseline: {auc - melhor_baseline:+.4f}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 3. A metrica que vai para a reuniao
# MAGIC
# MAGIC AUC e' metrica de quem treina. O diretor pergunta **quantos dos 200
# MAGIC compraram** -- sao perguntas diferentes, e a segunda paga a conta.
# MAGIC
# MAGIC O lift e' calculado **out-of-fold sobre a base inteira**, nao no
# MAGIC holdout: a fila real e' de 200 entre ~2.800. Num holdout de 704 os 200
# MAGIC primeiros seriam 28% da amostra, e o numero sairia otimista.

# COMMAND ----------

cv = StratifiedKFold(n_splits=5, shuffle=True, random_state=SEMENTE)
score_oof = cross_val_predict(
    HistGradientBoostingClassifier(**PARAMS), X, y, cv=cv, method="predict_proba"
)[:, 1]

fila = np.argsort(-score_oof)[:TAMANHO_FILA]
acertos_top200 = int(y.iloc[fila].sum())
taxa_top200 = acertos_top200 / TAMANHO_FILA
lift_top200 = float(taxa_top200 / taxa_base)

print(f"{'ESTRATEGIA':<38} {'DOS 200, QUANTOS COMPRAM':>26}")
print("-" * 65)
print(f"{'ligar as cegas':<38} {round(TAMANHO_FILA * taxa_base):>26}")
print(f"{'ligar para os 200 de maior score':<38} {acertos_top200:>26}")
print("-" * 65)
print(f"lift: {lift_top200:.2f}x")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 4. Importancia por permutacao

# COMMAND ----------

imp = permutation_importance(
    modelo, X_ho, y_ho, n_repeats=5, random_state=SEMENTE, scoring="roc_auc"
)
ordem = np.argsort(-imp.importances_mean)[:10]

print(f"{'FEATURE':<26} {'QUEDA NO AUC':>14}")
print("-" * 41)
for i in ordem:
    print(f"{FEATURES[i]:<26} {imp.importances_mean[i]:>14.4f}")

feature_top1 = FEATURES[ordem[0]]

# COMMAND ----------

# MAGIC %md
# MAGIC ## 5. MLflow: o modelo vira objeto do catalogo
# MAGIC
# MAGIC Mesmo catalogo das tabelas, mesmo GRANT, mesma linhagem. Nao e' um
# MAGIC `.pkl` no Drive de alguem que saiu da empresa.
# MAGIC
# MAGIC `mkdirs` ANTES de `set_experiment`: sem a pasta pai, o erro e'
# MAGIC `BAD_REQUEST: For input string: "None"`, que nao menciona pasta nenhuma.

# COMMAND ----------

w = WorkspaceClient()
usuario = w.current_user.me().user_name
PASTA_EXP = f"/Users/{usuario}/rotaperfume-ml"
w.workspace.mkdirs(PASTA_EXP)

mlflow.set_experiment(f"{PASTA_EXP}/propensao_compra")
mlflow.set_registry_uri("databricks-uc")

with mlflow.start_run(run_name="propensao_compra") as run:
    mlflow.log_params(PARAMS)
    mlflow.log_param("n_features", len(FEATURES))
    mlflow.log_param("referencia_treino", str(treino_pdf["_referencia"].iloc[0]))
    mlflow.log_metrics({
        "auc": auc,
        "lift_top200": lift_top200,
        "acertos_top200": acertos_top200,
        "taxa_base": taxa_base,
        "auc_baseline_recencia": auc_baseline["ligue para quem comprou recentemente"],
        "auc_baseline_valor": auc_baseline["ligue para quem compra mais"],
        "auc_baseline_atraso": auc_baseline["ligue para quem esta atrasado"],
    })
    # MLflow 2.22 no serverless: artifact_path=, nunca o name= do MLflow 3
    mlflow.sklearn.log_model(
        modelo,
        artifact_path="modelo",
        input_example=X_ho.head(3),
        registered_model_name=MODELO_UC,
    )
    run_id = run.info.run_id

cliente_mlflow = MlflowClient()
versoes = cliente_mlflow.search_model_versions(f"name='{MODELO_UC}'")
versao = max(int(v.version) for v in versoes)
cliente_mlflow.set_registered_model_alias(MODELO_UC, "prod", versao)
print(f"{MODELO_UC} versao {versao} registrada, alias @prod apontando para ela")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 6. Os tres testes que interrompem a tarefa

# COMMAND ----------

assert auc - melhor_baseline >= 0.05, (
    f"O modelo (AUC {auc:.4f}) nao ganha do melhor baseline "
    f"'{melhor_nome}' ({melhor_baseline:.4f}) por pelo menos 0,05. "
    "Se o modelo nao ganha da regra simples, o projeto nao se paga."
)

assert auc < 0.99, (
    f"AUC {auc:.4f} e' bom demais para ser competencia -- isso e' vazamento. "
    "Alguma feature esta olhando o futuro. Confira os filtros por data."
)

assert lift_top200 >= 2.5, (
    f"Lift de {lift_top200:.2f}x esta abaixo de 2,5x. A fila nao justifica "
    "o projeto: o comercial ligaria quase as cegas com mais trabalho."
)

print("os tres testes passaram")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 7. O score: os clientes com nota
# MAGIC
# MAGIC `predict_proba`, nunca `pyfunc.predict` -- este ultimo devolve a CLASSE
# MAGIC e transformaria a coluna inteira em zeros e uns.
# MAGIC
# MAGIC E nada de `spark_udf`: nao roda no serverless. 2.816 clientes cabem em
# MAGIC pandas com folga.

# COMMAND ----------

modelo_prod = mlflow.sklearn.load_model(f"models:/{MODELO_UC}@prod")

score_pdf = spark.table(f"{catalog}.gold.features_cliente").toPandas()

# a ordem das colunas vem do MODELO, nunca da tabela: se alguem acrescentar
# uma coluna na feature amanha, a tabela muda de ordem e o score sai errado
# sem nenhum erro.
colunas_modelo = list(modelo_prod.feature_names_in_)
score_pdf["score"] = modelo_prod.predict_proba(score_pdf[colunas_modelo])[:, 1]

saida = score_pdf[["cliente_id", "_referencia", "score"]].copy()
saida["versao_modelo"] = int(versao)

sdf = (
    spark.createDataFrame(saida)
    .withColumn("cliente_id", F.col("cliente_id").cast("int"))
    .withColumn("score", F.col("score").cast("double"))
)

faixas = F.ntile(4).over(Window.orderBy(F.col("score")))
sdf = sdf.withColumn(
    "faixa",
    F.when(faixas == 1, "Fria").when(faixas == 2, "Morna")
     .when(faixas == 3, "Quente").otherwise("Muito quente"),
).select("cliente_id", "score", "faixa", "_referencia", "versao_modelo")

TAB_SCORE = f"{catalog}.gold.score_propensao"
sdf.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(TAB_SCORE)
spark.sql(
    f"COMMENT ON TABLE {TAB_SCORE} IS "
    "'Um score de propensao de compra por cliente, com a faixa (Fria, Morna, Quente, "
    "Muito quente) e a versao do modelo que gerou. Ordenar por score DESC da a fila de "
    "ligacoes. O corte usado esta em _referencia.'"
)
print(f"{TAB_SCORE}: {sdf.count():,} clientes pontuados")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 8. As metricas tambem viram tabela
# MAGIC
# MAGIC O Genie nao le MLflow, e daqui a seis meses ninguem abre a interface de
# MAGIC experimento. O que precisa sobreviver vira tabela na gold.

# COMMAND ----------

metricas = spark.createDataFrame(pd.DataFrame([{
    "versao": int(versao),
    "auc": auc,
    "lift_top200": lift_top200,
    "acertos_top200": acertos_top200,
    "taxa_base": taxa_base,
    "auc_baseline_recencia": auc_baseline["ligue para quem comprou recentemente"],
    "auc_baseline_valor": auc_baseline["ligue para quem compra mais"],
    "auc_baseline_atraso": auc_baseline["ligue para quem esta atrasado"],
    "feature_numero_1": feature_top1,
    "run_id": run_id,
}])).withColumn("_treinado_em", F.current_timestamp())

TAB_METRICAS = f"{catalog}.gold.modelo_metricas"
metricas.write.mode("append").option("mergeSchema", "true").saveAsTable(TAB_METRICAS)
spark.sql(
    f"COMMENT ON TABLE {TAB_METRICAS} IS "
    "'Uma linha por treino do modelo de propensao: AUC, lift dos 200 primeiros, acertos, "
    "taxa base e o AUC de cada baseline simples. Existe porque o Genie nao le MLflow e "
    "porque daqui a seis meses ninguem abre a interface de experimento.'"
)

# calibragem: a prova que o comercial confere sozinho, sem saber o que e' AUC
holdout = X_ho.copy()
holdout["comprou"] = y_ho.values
holdout["score"] = modelo.predict_proba(X_ho)[:, 1]
holdout["faixa"] = pd.qcut(
    holdout["score"], 4, labels=["Fria", "Morna", "Quente", "Muito quente"]
)

calib = (
    holdout.groupby("faixa", observed=True)
    .agg(clientes=("comprou", "size"), compraram=("comprou", "sum"),
         score_medio=("score", "mean"))
    .reset_index()
)
calib["faixa"] = calib["faixa"].astype(str)
calib["taxa_de_compra"] = calib["compraram"] / calib["clientes"]

TAB_CALIB = f"{catalog}.gold.calibragem_holdout"
(spark.createDataFrame(calib)
 .withColumn("_treinado_em", F.current_timestamp())
 .write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(TAB_CALIB))
spark.sql(
    f"COMMENT ON TABLE {TAB_CALIB} IS "
    "'Taxa de compra observada por faixa de score, medida no holdout. Se a taxa sobe da "
    "faixa Fria para a Muito quente, o score ordena -- e ninguem precisa saber o que e "
    "curva ROC para conferir isso.'"
)

print(calib.to_string(index=False))

# COMMAND ----------

print(f"modelo versao {versao} | AUC {auc:.4f} | lift {lift_top200:.2f}x "
      f"| {acertos_top200} dos {TAMANHO_FILA} compraram")
