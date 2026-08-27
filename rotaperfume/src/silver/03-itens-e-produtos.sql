-- =====================================================================
-- silver.produtos e silver.itens_pedido
-- =====================================================================
-- A DECISAO DA NOITE mora neste arquivo: quantidade negativa em
-- itens_pedido NAO e' erro, e' DEVOLUCAO. Sao 2.327 itens.
--
-- Tres caminhos possiveis, e cada um da um numero diferente ao diretor:
--   1. descartar a devolucao      -> o faturamento INFLA em R$ 1,26 milhao
--   2. manter, sem flag           -> toda soma da empresa fica poluida
--   3. manter, COM flag           -> preserva os dois numeros
-- O caminho 3 e' o unico que deixa a analise decidir se quer bruto ou
-- liquido. E' o que a coluna `devolucao` faz. NENHUMA linha e' descartada.
-- =====================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.produtos AS
SELECT
  trim(sku)                        AS sku,
  nullif(trim(descricao), '')      AS descricao,
  nullif(trim(categoria), '')      AS categoria,
  nullif(trim(marca), '')          AS marca,
  nullif(trim(nota_olfativa), '')  AS nota_olfativa,
  try_cast(trim(preco_tabela) AS DECIMAL(18,2))    AS preco_tabela,
  try_cast(trim(custo_unitario) AS DECIMAL(18,2))  AS custo_unitario,
  nullif(trim(unidade), '')        AS unidade,
  CASE WHEN upper(trim(ativo)) = 'S' THEN true
       WHEN upper(trim(ativo)) = 'N' THEN false END AS ativo,
  coalesce(
    try_to_date(trim(data_lancamento)),
    try_to_date(trim(data_lancamento), 'dd/MM/yyyy')
  ) AS data_lancamento,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.produtos) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.produtos;

COMMENT ON TABLE lakehouse_rotaperfume.silver.produtos IS
  'Catalogo de produtos tipado. custo_unitario e a base do calculo de margem da gold.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.produtos.ativo IS
  'Produto ativo na linha atual. Produto inativo nao impede venda historica: 76 itens ja vendidos apontam para SKU descontinuado.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.produtos.data_lancamento IS
  'Data de lancamento, convertida com coalesce de dois try_to_date. Nula para produtos sem data na origem.';

-- =====================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.itens_pedido AS
WITH base AS (
  SELECT
    CAST(i.item_id AS INT)   AS item_id,
    CAST(i.pedido_id AS INT) AS pedido_id,
    trim(i.sku)              AS sku,
    CAST(i.quantidade AS INT) AS quantidade,
    try_cast(trim(i.preco_praticado) AS DECIMAL(18,2)) AS preco_praticado,
    try_cast(trim(i.desconto_pct) AS DECIMAL(9,4))     AS desconto_pct,
    try_cast(trim(i.valor_bruto) AS DECIMAL(18,2))     AS valor_bruto,
    p.ativo AS produto_ativo
  FROM lakehouse_rotaperfume.bronze.itens_pedido i
  -- LEFT JOIN de proposito: se um SKU sumisse do catalogo, o item NAO pode
  -- desaparecer da silver. Perder linha aqui mudaria o faturamento.
  LEFT JOIN lakehouse_rotaperfume.silver.produtos p ON p.sku = trim(i.sku)
)
SELECT
  item_id,
  pedido_id,
  sku,
  quantidade,
  -- a flag que preserva os dois numeros
  quantidade < 0 AS devolucao,
  abs(quantidade) AS quantidade_abs,
  preco_praticado,
  desconto_pct,
  valor_bruto,
  -- expoe o problema em vez de conserta-lo: o item foi vendido, o produto
  -- saiu de linha depois. Quem decide o que fazer com isso e' o negocio.
  coalesce(NOT produto_ativo, false) AS sku_descontinuado,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.itens_pedido) AS _linhas_origem
FROM base;

COMMENT ON TABLE lakehouse_rotaperfume.silver.itens_pedido IS
  'Itens de pedido tipados, com devolucao sinalizada e nunca descartada. 197.724 linhas -- o mesmo numero da bronze.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.itens_pedido.quantidade IS
  'Quantidade com o sinal da origem: NEGATIVA em 2.327 itens, que sao devolucoes. Some esta coluna para obter o valor liquido.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.itens_pedido.devolucao IS
  'Item devolvido (quantidade negativa na origem). Descartar estes itens inflaria o faturamento em R$ 1,26 milhao. A flag existe para a analise escolher entre bruto e liquido.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.itens_pedido.quantidade_abs IS
  'Quantidade em modulo, sempre positiva. Use para contar volume fisico movimentado. Use quantidade para somar valor.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.itens_pedido.sku_descontinuado IS
  'Item cujo produto nao esta mais ativo no catalogo (76 itens). Nao e erro: a venda aconteceu antes de o produto sair de linha.';

-- ---------------------------------------------------------------------
-- O CONTRATO
-- ---------------------------------------------------------------------
ALTER TABLE lakehouse_rotaperfume.silver.itens_pedido DROP CONSTRAINT IF EXISTS quantidade_abs_positiva;
ALTER TABLE lakehouse_rotaperfume.silver.itens_pedido
  ADD CONSTRAINT quantidade_abs_positiva CHECK (quantidade_abs > 0);
