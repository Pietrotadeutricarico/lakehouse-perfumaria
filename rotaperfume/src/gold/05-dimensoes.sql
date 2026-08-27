-- =====================================================================
-- gold: as quatro dimensoes conformadas
-- =====================================================================
-- Le SO' da silver -- nunca da bronze. Se uma dimensao lesse a bronze, a
-- regra de limpeza estaria escrita em dois lugares, e um dia os dois
-- divergiriam sem ninguem perceber.
--
-- "Conformada" significa que a mesma dimensao serve todos os marts: existe
-- UM dim_cliente, nao um por diretoria. E' o que faz os numeros fecharem
-- entre areas.
-- =====================================================================

-- ---------------------------------------------------------------------
-- dim_cliente: uma linha por cliente, com o comportamento de compra junto
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_cliente AS
WITH referencia AS (
  -- A base termina em 2026-08-31. Usar current_date() como "hoje" daria
  -- dias_sem_comprar NEGATIVO para quem comprou depois da data de execucao.
  -- A referencia e' o ultimo pedido da base, e isso esta no COMMENT da
  -- coluna para ninguem interpretar o numero errado.
  SELECT max(data_pedido) AS hoje FROM lakehouse_rotaperfume.silver.pedidos
),
compras AS (
  SELECT
    cliente_id,
    min(data_pedido)                     AS data_primeiro_pedido,
    max(data_pedido)                     AS data_ultimo_pedido,
    count(*)                             AS total_pedidos,
    sum(valor_liquido)                   AS receita_acumulada
  FROM lakehouse_rotaperfume.silver.pedidos
  WHERE NOT cancelado
  GROUP BY cliente_id
)
SELECT
  c.cliente_id,
  c.cnpj,
  c.razao_social,
  c.segmento,
  c.cidade,
  c.uf,
  c.bairro,
  c.data_cadastro,
  c.ativo,
  co.data_primeiro_pedido,
  co.data_ultimo_pedido,
  coalesce(co.total_pedidos, 0) AS total_pedidos,
  coalesce(co.receita_acumulada, CAST(0 AS DECIMAL(18,2))) AS receita_acumulada,
  datediff(r.hoje, co.data_ultimo_pedido) AS dias_sem_comprar,
  current_timestamp() AS _processado_em
FROM lakehouse_rotaperfume.silver.clientes c
LEFT JOIN compras co ON co.cliente_id = c.cliente_id
CROSS JOIN referencia r;

COMMENT ON TABLE lakehouse_rotaperfume.gold.dim_cliente IS
  'Uma linha por cliente ativo ou inativo, com o resumo de compras junto. Conformada: e a unica dimensao de cliente da gold, usada por todos os marts.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.dim_cliente.receita_acumulada IS
  'Total ja comprado pelo cliente, excluindo pedidos cancelados e ja liquido de devolucoes. Zero para cliente que nunca comprou.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.dim_cliente.dias_sem_comprar IS
  'Dias entre a ultima compra do cliente e a data do pedido mais recente da BASE (nao a data de hoje). Nulo para cliente que nunca comprou. Quanto maior, maior o risco de perda do cliente.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.dim_cliente.total_pedidos IS
  'Quantidade de pedidos nao cancelados do cliente.';

-- ---------------------------------------------------------------------
-- dim_produto: uma linha por SKU
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_produto AS
SELECT
  sku,
  descricao,
  categoria,
  marca,
  nota_olfativa,
  unidade,
  custo_unitario,
  preco_tabela,
  -- margem de tabela: o quanto o produto renderia no preco cheio. A margem
  -- REALIZADA esta no fato, porque depende do preco praticado na venda.
  CASE WHEN preco_tabela > 0
       THEN round(100 * (preco_tabela - custo_unitario) / preco_tabela, 2) END
    AS margem_tabela_pct,
  data_lancamento,
  ativo,
  NOT ativo AS descontinuado,
  current_timestamp() AS _processado_em
FROM lakehouse_rotaperfume.silver.produtos;

COMMENT ON TABLE lakehouse_rotaperfume.gold.dim_produto IS
  'Uma linha por SKU do catalogo, com custo e preco de tabela para analise de margem.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.dim_produto.margem_tabela_pct IS
  'Margem percentual no preco de tabela, sem considerar desconto praticado na venda. A margem realizada esta em fato_vendas, que usa o preco efetivamente cobrado.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.dim_produto.descontinuado IS
  'Produto fora de linha. Vendas historicas do SKU continuam validas e permanecem no fato.';

-- ---------------------------------------------------------------------
-- dim_vendedor
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_vendedor AS
SELECT
  v.vendedor_id,
  v.nome,
  v.regiao,
  v.uf,
  v.data_admissao,
  v.data_desligamento,
  v.meta_mensal,
  v.ativo,
  -- trazido da carteira para o gestor ver o tamanho do problema sem
  -- precisar fazer join: sao clientes sem responsavel comercial.
  coalesce(ca.clientes_orfaos, 0) AS clientes_sem_responsavel,
  current_timestamp() AS _processado_em
FROM lakehouse_rotaperfume.silver.vendedores v
LEFT JOIN (
  SELECT vendedor_id, count(*) AS clientes_orfaos
  FROM lakehouse_rotaperfume.silver.carteira
  WHERE orfao_vendedor_desligado
  GROUP BY vendedor_id
) ca ON ca.vendedor_id = v.vendedor_id;

COMMENT ON TABLE lakehouse_rotaperfume.gold.dim_vendedor IS
  'Uma linha por vendedor, com a meta mensal usada no calculo de atingimento do mart comercial.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.dim_vendedor.clientes_sem_responsavel IS
  'Clientes que seguem na carteira deste vendedor mesmo apos o desligamento dele (441 casos no total). Problema de processo exposto de proposito, nao corrigido no dado.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.dim_vendedor.meta_mensal IS
  'Meta de receita mensal do vendedor, em reais. Base do campo atingimento_pct do mart comercial.';

-- ---------------------------------------------------------------------
-- dim_calendario: um dia por linha, cobrindo os 24 meses da base
-- ---------------------------------------------------------------------
-- Medido: a base vai de 2024-09-01 a 2026-08-31, exatamente 24 meses.
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_calendario AS
SELECT
  dia AS data,
  year(dia)    AS ano,
  month(dia)   AS mes,
  CASE month(dia)
    WHEN 1 THEN 'Janeiro'  WHEN 2 THEN 'Fevereiro' WHEN 3 THEN 'Marco'
    WHEN 4 THEN 'Abril'    WHEN 5 THEN 'Maio'      WHEN 6 THEN 'Junho'
    WHEN 7 THEN 'Julho'    WHEN 8 THEN 'Agosto'    WHEN 9 THEN 'Setembro'
    WHEN 10 THEN 'Outubro' WHEN 11 THEN 'Novembro' WHEN 12 THEN 'Dezembro'
  END AS nome_mes,
  concat('T', CAST(quarter(dia) AS STRING)) AS trimestre,
  dayofweek(dia) AS dia_semana_num,
  CASE dayofweek(dia)
    WHEN 1 THEN 'Domingo' WHEN 2 THEN 'Segunda' WHEN 3 THEN 'Terca'
    WHEN 4 THEN 'Quarta'  WHEN 5 THEN 'Quinta'  WHEN 6 THEN 'Sexta'
    WHEN 7 THEN 'Sabado'
  END AS dia_semana,
  dayofweek(dia) IN (1, 7) AS fim_de_semana,
  -- regra de NEGOCIO do setor, escrita uma vez aqui em vez de repetida em
  -- cada query de sazonalidade
  month(dia) IN (4, 6, 10) AS mes_pico_setor,
  current_timestamp() AS _processado_em
FROM (
  SELECT explode(sequence(DATE'2024-09-01', DATE'2026-08-31', INTERVAL 1 DAY)) AS dia
);

COMMENT ON TABLE lakehouse_rotaperfume.gold.dim_calendario IS
  'Um dia por linha cobrindo os 24 meses da base (2024-09-01 a 2026-08-31). Existe para que analise por trimestre, dia da semana ou mes de pico nao precise recalcular a regra em cada query.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.dim_calendario.mes_pico_setor IS
  'Abril, junho e outubro: meses de pico do setor de perfumaria (Dia das Maes, Dia dos Namorados e antecipacao de fim de ano). Regra de negocio, nao derivada do dado.';
