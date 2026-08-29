-- Os quatro numeros do topo da tela.
-- Uma linha so': a fila da semana, o desempenho do modelo e o retorno ja registrado.
SELECT
  f.contatos,
  f.vendedores,
  f.receita_esperada,
  f.referencia,
  m.versao,
  m.acertos_top200,
  m.lift_top200,
  m.taxa_base,
  r.trabalhados,
  r.viraram_pedido
FROM (
  SELECT COUNT(*)                    AS contatos,
         COUNT(DISTINCT vendedor)    AS vendedores,
         SUM(score * ticket_medio)   AS receita_esperada,
         MIN(_referencia)            AS referencia
  FROM lakehouse_rotaperfume.gold.fila_semanal
) f
CROSS JOIN (
  -- a ULTIMA versao do modelo, nao uma qualquer
  SELECT versao, acertos_top200, lift_top200, taxa_base
  FROM lakehouse_rotaperfume.gold.modelo_metricas
  QUALIFY ROW_NUMBER() OVER (ORDER BY versao DESC) = 1
) m
CROSS JOIN (
  SELECT COUNT(*) AS trabalhados,
         COALESCE(SUM(CASE WHEN status = 'vendeu' THEN 1 ELSE 0 END), 0) AS viraram_pedido
  FROM lakehouse_rotaperfume.gold.retorno_ligacao
) r
