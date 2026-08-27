#!/usr/bin/env bash
#
# Roda UMA tarefa do rotaperfume_pipeline, em vez do job inteiro.
#
# POR QUE ISSO EXISTE: cada tarefa serverless paga o proprio tempo de partida,
# e o job inteiro paga uma vez por tarefa. Rodar tudo para testar uma mudanca
# de um arquivo e' esperar minutos por tentativa.
#
# O job completo continua valendo -- UMA vez, no fim, quando a tarefa ja
# funciona e voce quer ver o DAG inteiro verde. Nao como forma de testar.
#
# Uso: bash scripts/rodar-tarefa.sh <profile> <tarefa>
#      bash scripts/rodar-tarefa.sh DEFAULT ml_features
#
# Prefixe a tarefa com + para rodar tambem o que vem ANTES dela, e sufixe
# com + para rodar o que vem DEPOIS:  +ml_features  /  ml_features+
set -euo pipefail

PROFILE="${1:?informe o profile, ex: bash scripts/rodar-tarefa.sh DEFAULT ml_features}"
TAREFA="${2:?informe a tarefa, ex: ml_features}"

echo ">> rodando somente a tarefa '${TAREFA}' (profile: ${PROFILE})"
databricks bundle run rotaperfume_pipeline \
  --target dev --profile "${PROFILE}" --only "${TAREFA}"
