-- =====================================================================
-- gold: tres marts, UM fato
-- =====================================================================
-- O erro classico e' criar fato_vendas_comercial e fato_vendas_produto.
-- Em tres meses eles divergem e ninguem sabe qual esta certo. O que separa
-- um mart do outro e' a DIMENSAO DOMINANTE e as METRICAS -- nunca a tabela
-- base. Os tres aqui leem exclusivamente de gold.fato_vendas.
--
-- "Conformado" significa que eles SOMAM IGUAL: mart_vendas_por_vendedor e
-- mart_produto_performance fecham no mesmo R$ 102.303.828,05 do fato e da
-- silver. E' o teste 8.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Diretoria COMERCIAL: como cada vendedor performou no mes
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.mart_vendas_por_vendedor AS
WITH por_vendedor_mes AS (
  SELECT
    f.vendedor_id,
    f.ano,
    f.mes,
    sum(f.receita)                    AS receita,
    sum(f.margem)                     AS margem,
    count(DISTINCT f.pedido_id)       AS pedidos,
    count(DISTINCT f.cliente_id)      AS clientes_atendidos,
    sum(f.quantidade)                 AS itens_vendidos,
    sum(f.receita) FILTER (WHERE f.devolucao) AS receita_devolvida
  FROM lakehouse_rotaperfume.gold.fato_vendas f
  GROUP BY f.vendedor_id, f.ano, f.mes
)
SELECT
  v.vendedor_id,
  v.nome           AS vendedor,
  v.regiao,
  v.ativo          AS vendedor_ativo,
  m.ano,
  m.mes,
  m.receita,
  m.margem,
  CASE WHEN m.receita <> 0
       THEN round(100 * m.margem / m.receita, 2) END AS margem_pct,
  v.meta_mensal    AS meta,
  CASE WHEN v.meta_mensal > 0
       THEN round(100 * m.receita / v.meta_mensal, 2) END AS atingimento_pct,
  m.pedidos,
  m.clientes_atendidos,
  m.itens_vendidos,
  CASE WHEN m.pedidos > 0
       THEN round(m.receita / m.pedidos, 2) END AS ticket_medio,
  coalesce(m.receita_devolvida, CAST(0 AS DECIMAL(18,2))) AS receita_devolvida,
  current_timestamp() AS _processado_em
FROM por_vendedor_mes m
LEFT JOIN lakehouse_rotaperfume.gold.dim_vendedor v ON v.vendedor_id = m.vendedor_id;

COMMENT ON TABLE lakehouse_rotaperfume.gold.mart_vendas_por_vendedor IS
  'Diretoria comercial. Grao vendedor x mes. SUM(receita) fecha no mesmo total do fato: R$ 102.303.828,05.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.mart_vendas_por_vendedor.atingimento_pct IS
  'Receita do mes dividida pela meta mensal do vendedor, em percentual. Acima de 100 significa meta batida. A meta e fixa por vendedor, nao muda por mes.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.mart_vendas_por_vendedor.ticket_medio IS
  'Receita liquida dividida pelo numero de pedidos distintos do mes. Ja considera devolucoes, entao um mes com muita devolucao derruba o ticket.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.mart_vendas_por_vendedor.clientes_atendidos IS
  'Clientes distintos que compraram com este vendedor no mes. Nao e o tamanho da carteira dele.';

-- ---------------------------------------------------------------------
-- Diretoria de PRODUTO: performance por SKU, com curva ABC
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.mart_produto_performance AS
WITH por_sku_mes AS (
  SELECT
    f.sku, f.ano, f.mes,
    sum(f.receita)     AS receita,
    sum(f.margem)      AS margem,
    sum(f.custo)       AS custo,
    sum(f.quantidade)  AS quantidade,
    count(DISTINCT f.pedido_id) AS pedidos,
    sum(f.quantidade) FILTER (WHERE f.devolucao) AS quantidade_devolvida
  FROM lakehouse_rotaperfume.gold.fato_vendas f
  GROUP BY f.sku, f.ano, f.mes
),
-- A curva ABC e calculada sobre o TOTAL do SKU no periodo inteiro, nao
-- mes a mes: classificacao mensal oscilaria a cada mes fraco e perderia o
-- sentido de "produto A". A classe e a mesma em todas as linhas do SKU.
total_por_sku AS (
  SELECT sku, sum(receita) AS receita_sku
  FROM por_sku_mes GROUP BY sku
),
abc AS (
  SELECT
    sku,
    receita_sku,
    sum(receita_sku) OVER (ORDER BY receita_sku DESC
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
      / sum(receita_sku) OVER () AS acumulado_pct
  FROM total_por_sku
)
SELECT
  m.sku,
  p.descricao,
  p.categoria,
  p.marca,
  p.descontinuado,
  m.ano,
  m.mes,
  m.receita,
  m.custo,
  m.margem,
  CASE WHEN m.receita <> 0
       THEN round(100 * m.margem / m.receita, 2) END AS margem_pct,
  m.quantidade,
  coalesce(m.quantidade_devolvida, 0) AS quantidade_devolvida,
  m.pedidos,
  CASE WHEN a.acumulado_pct <= 0.80 THEN 'A'
       WHEN a.acumulado_pct <= 0.95 THEN 'B'
       ELSE 'C' END AS curva_abc,
  a.receita_sku AS receita_total_sku,
  current_timestamp() AS _processado_em
FROM por_sku_mes m
LEFT JOIN abc a ON a.sku = m.sku
LEFT JOIN lakehouse_rotaperfume.gold.dim_produto p ON p.sku = m.sku;

COMMENT ON TABLE lakehouse_rotaperfume.gold.mart_produto_performance IS
  'Diretoria de produto. Grao SKU x mes, com curva ABC. SUM(receita) fecha no mesmo total do fato: R$ 102.303.828,05 -- e o teste 8 verifica isso.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.mart_produto_performance.curva_abc IS
  'Classificacao ABC por receita acumulada no periodo INTEIRO (A ate 80 por cento da receita, B ate 95, C o restante). Nao e recalculada por mes: um produto A continua A no mes fraco.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.mart_produto_performance.margem_pct IS
  'Margem do mes dividida pela receita do mes. Kit Presente e a categoria de menor margem (33 por cento) e Oleo Concentrado a maior (49,9 por cento).';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.mart_produto_performance.quantidade_devolvida IS
  'Unidades devolvidas no mes, ja com sinal negativo. Quanto mais proximo de zero, melhor.';

-- ---------------------------------------------------------------------
-- Diretoria FINANCEIRA: recebimento por mes de vencimento
-- ---------------------------------------------------------------------
-- Este mart NAO fecha com o fato de proposito: o universo dele e' o de
-- PAGAMENTOS, nao o de vendas. Um pedido pode ser parcelado em varios
-- vencimentos, e um pedido cancelado ainda pode ter registro financeiro.
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento AS
SELECT
  year(pg.data_vencimento)  AS ano_vencimento,
  month(pg.data_vencimento) AS mes_vencimento,
  pg.forma_pagamento,
  count(*)                             AS titulos,
  sum(pg.valor)                        AS valor_a_receber,
  sum(pg.valor) FILTER (WHERE pg.pago) AS valor_recebido,
  sum(pg.valor) FILTER (WHERE NOT pg.pago) AS valor_em_aberto,
  round(100 * coalesce(sum(pg.valor) FILTER (WHERE pg.pago), 0) / sum(pg.valor), 2)
    AS recebido_pct,
  round(avg(pg.dias_atraso) FILTER (WHERE pg.dias_atraso > 0), 1) AS atraso_medio_dias,
  count(*) FILTER (WHERE pg.dias_atraso > 0) AS titulos_em_atraso,
  sum(pg.custo_taxa)                   AS custo_taxa,
  current_timestamp() AS _processado_em
FROM lakehouse_rotaperfume.silver.pagamentos pg
WHERE pg.data_vencimento IS NOT NULL
GROUP BY year(pg.data_vencimento), month(pg.data_vencimento), pg.forma_pagamento;

COMMENT ON TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento IS
  'Diretoria financeira. Grao mes de vencimento x forma de pagamento. NAO fecha com fato_vendas de proposito: o universo e o de titulos a receber, nao o de vendas -- um pedido parcelado gera varios vencimentos.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.mart_financeiro_recebimento.atraso_medio_dias IS
  'Media de dias de atraso entre os titulos que atrasaram. Titulos pagos em dia ou adiantados nao entram na media, para nao diluir o indicador. Nulo quando nenhum titulo do grupo atrasou.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.mart_financeiro_recebimento.custo_taxa IS
  'Total retido pelas operadoras (diferenca entre valor e valor liquido). E o custo real de oferecer cada forma de pagamento.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.mart_financeiro_recebimento.valor_em_aberto IS
  'Titulos ainda nao pagos com vencimento neste mes. Vencimento no futuro tambem aparece aqui.';
