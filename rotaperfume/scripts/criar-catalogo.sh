#!/usr/bin/env bash
#
# Cria o catalogo lakehouse_rotaperfume.
#
# POR QUE ISSO NAO ESTA NO BUNDLE:
#   No Databricks Free Edition o Default Storage esta ligado, e nessa
#   configuracao a API do Unity Catalog RECUSA criar catalogo -- ela exige um
#   MANAGED LOCATION que a conta gratuita nao tem:
#
#     Error: Metastore storage root URL does not exist.
#            Default Storage is enabled in your account. (400 INVALID_STATE)
#
#   O comando SQL funciona. Por isso o catalogo nasce aqui, e todo o RESTO
#   (schemas e volumes) e' recurso do bundle, em resources/catalogo.yml.
#
# Uso: bash scripts/criar-catalogo.sh <profile>
set -euo pipefail

PROFILE="${1:?informe o profile do Databricks CLI, ex: bash scripts/criar-catalogo.sh DEFAULT}"
CATALOG="lakehouse_rotaperfume"

echo ">> criando catalogo ${CATALOG} (profile: ${PROFILE})"
echo "   se o SQL Warehouse estiver parado, a primeira query acorda ele (~30s)"

databricks experimental aitools tools query \
  "CREATE CATALOG IF NOT EXISTS ${CATALOG}
   COMMENT 'Lakehouse da RotaPerfume: dados de ERP e CRM em bronze, silver e gold.'" \
  --profile "${PROFILE}"

echo ">> pronto. conferindo:"
databricks catalogs get "${CATALOG}" --profile "${PROFILE}" --output json \
  | grep -E '"(name|comment)"'
