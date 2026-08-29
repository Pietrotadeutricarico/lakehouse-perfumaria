-- Quanto da fila ja foi trabalhado, por vendedor.
-- Comeca com trabalhados = 0 em todas as linhas: ninguem ligou ainda, e esse
-- e' o estado correto no inicio da semana.
WITH ultimo_retorno AS (
  SELECT cliente_id, status
  FROM lakehouse_rotaperfume.gold.retorno_ligacao
  QUALIFY ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY registrado_em DESC) = 1
)
SELECT
  f.vendedor,
  COUNT(*)                                                          AS na_fila,
  COUNT(r.cliente_id)                                               AS trabalhados,
  SUM(CASE WHEN r.status = 'vendeu'        THEN 1 ELSE 0 END)        AS vendeu,
  SUM(CASE WHEN r.status = 'vai_pensar'    THEN 1 ELSE 0 END)        AS vai_pensar,
  SUM(CASE WHEN r.status = 'sem_interesse' THEN 1 ELSE 0 END)        AS sem_interesse,
  SUM(CASE WHEN r.status = 'nao_atendeu'   THEN 1 ELSE 0 END)        AS nao_atendeu
FROM lakehouse_rotaperfume.gold.fila_semanal f
LEFT JOIN ultimo_retorno r ON r.cliente_id = f.cliente_id
GROUP BY f.vendedor
ORDER BY na_fila DESC, f.vendedor
