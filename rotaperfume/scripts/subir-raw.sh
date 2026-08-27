#!/usr/bin/env bash
#
# Sobe os CSVs de erp/ e crm/ (na raiz do repositorio) para o Volume do
# Unity Catalog: /Volumes/lakehouse_rotaperfume/bronze/raw/{erp,crm}
#
# DETALHE QUE PEGA: `databricks fs cp` exige o esquema `dbfs:` no destino,
# mesmo o destino sendo um Volume do UC -- e nao DBFS.
#
# Uso: bash scripts/subir-raw.sh <profile>
set -euo pipefail

PROFILE="${1:?informe o profile do Databricks CLI, ex: bash scripts/subir-raw.sh DEFAULT}"
CATALOG="lakehouse_rotaperfume"

# a raiz do repo e' o diretorio pai deste bundle
REPO_RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DESTINO="dbfs:/Volumes/${CATALOG}/bronze/raw"

for sistema in erp crm; do
  origem="${REPO_RAIZ}/${sistema}"
  if [ ! -d "${origem}" ]; then
    echo "ERRO: ${origem} nao existe. Os CSVs de origem ficam em erp/ e crm/ na raiz do repositorio." >&2
    exit 1
  fi
  echo ">> subindo ${sistema}/ ($(ls -1 "${origem}"/*.csv | wc -l) arquivos) -> ${DESTINO}/${sistema}"
  databricks fs cp --recursive --overwrite "${origem}" "${DESTINO}/${sistema}" --profile "${PROFILE}"
done

echo ">> pronto. conferindo o que chegou:"
for sistema in erp crm; do
  echo "--- ${sistema}"
  databricks fs ls "${DESTINO}/${sistema}" --profile "${PROFILE}"
done
