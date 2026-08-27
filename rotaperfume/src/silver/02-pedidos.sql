-- =====================================================================
-- silver.pedidos -- tipos certos e o cancelamento explicito
-- =====================================================================
-- Na bronze, valor_total e' TEXTO: ordenar por ele coloca '9999.61' na
-- frente de '39983.27'. Aqui vira DECIMAL, e a pergunta "quais os maiores
-- pedidos" passa a ter uma resposta so'.
--
-- O pedido cancelado chega com valor zerado e NENHUMA flag clara -- so' o
-- status em texto. Criar a coluna booleana torna a regra visivel para quem
-- consome, em vez de exigir que cada analista lembre de filtrar por string.
-- =====================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.pedidos AS
WITH base AS (
  SELECT
    CAST(pedido_id AS INT)   AS pedido_id,
    CAST(cliente_id AS INT)  AS cliente_id,
    CAST(vendedor_id AS INT) AS vendedor_id,
    -- dois formatos no mesmo campo, como em clientes
    coalesce(
      try_to_date(trim(data_pedido)),
      try_to_date(trim(data_pedido), 'dd/MM/yyyy')
    ) AS data_pedido,
    nullif(trim(canal), '')  AS canal,
    nullif(trim(status), '') AS status,
    try_cast(trim(valor_total) AS DECIMAL(18,2)) AS valor_total
  FROM lakehouse_rotaperfume.bronze.pedidos
)
SELECT
  pedido_id,
  cliente_id,
  vendedor_id,
  data_pedido,
  canal,
  status,
  valor_total,
  status = 'Cancelado' AS cancelado,
  -- valor_liquido e' o que a empresa efetivamente vendeu naquele pedido:
  -- cancelado nao entra em soma de faturamento.
  CASE WHEN status = 'Cancelado' THEN CAST(0 AS DECIMAL(18,2))
       ELSE valor_total END AS valor_liquido,
  year(data_pedido)  AS ano,
  month(data_pedido) AS mes,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.pedidos) AS _linhas_origem
FROM base;

-- ---------------------------------------------------------------------
COMMENT ON TABLE lakehouse_rotaperfume.silver.pedidos IS
  'Pedidos tipados, com o cancelamento promovido a coluna booleana. SUM(valor_liquido) reproduz o faturamento da bronze: R$ 102.303.828,05.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.pedidos.data_pedido IS
  'Data do pedido. Na origem vinha em ISO e em dd/MM/yyyy no mesmo campo, convertida com coalesce de dois try_to_date porque ANSI mode aborta a query em to_date sobre data malformada.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.pedidos.cancelado IS
  'Pedido cancelado. Na origem so existia o status em texto, sem flag: 957 pedidos cancelados chegam com valor zerado e nada que os distinga em uma soma.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.pedidos.valor_liquido IS
  'Valor efetivamente vendido: zero quando cancelado, valor_total caso contrario. E a coluna certa para somar faturamento. Pode ser NEGATIVO em 135 pedidos que contem item devolvido -- isso e negocio legitimo, nao sujeira.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.pedidos._linhas_origem IS
  'Linhas lidas da bronze. Nenhuma linha e descartada aqui: cancelado fica, com flag.';

-- ---------------------------------------------------------------------
-- O CONTRATO
-- ---------------------------------------------------------------------
ALTER TABLE lakehouse_rotaperfume.silver.pedidos DROP CONSTRAINT IF EXISTS data_pedido_obrigatoria;
ALTER TABLE lakehouse_rotaperfume.silver.pedidos
  ADD CONSTRAINT data_pedido_obrigatoria CHECK (data_pedido IS NOT NULL);

-- ATENCAO: a regra intuitiva aqui seria `valor_liquido >= 0`, e ela FALHA.
-- 135 pedidos tem valor negativo, e nao e' sujeira: sao pedidos que contem
-- item devolvido, e o saldo do pedido virou negativo. Negocio legitimo.
-- A regra que realmente queremos garantir e' outra: pedido cancelado tem
-- que ter valor ZERO.
ALTER TABLE lakehouse_rotaperfume.silver.pedidos DROP CONSTRAINT IF EXISTS pedido_cancelado_zerado;
ALTER TABLE lakehouse_rotaperfume.silver.pedidos
  ADD CONSTRAINT pedido_cancelado_zerado CHECK (NOT cancelado OR valor_liquido = 0);
