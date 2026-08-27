-- =====================================================================
-- silver: vendedores, carteira, oportunidades, visitas, pagamentos, estoque
-- =====================================================================
-- Duas armadilhas moram aqui:
--
-- 1. CARTEIRA. Existe vendedor DESLIGADO com carteira vigente -- 441 casos.
--    A tentacao e' "consertar" fechando a carteira. Nao. Consertar apaga a
--    evidencia de um problema de processo que alguem precisa resolver. A
--    silver EXPOE: `vigente` diz a verdade operacional, e
--    `orfao_vendedor_desligado` entrega o problema ao gestor.
--
-- 2. OPORTUNIDADES. As etapas na origem sao 'Fechado ganho' e
--    'Fechado perdido' -- NAO 'Ganha' e 'Perdida'. Conferido com
--    SELECT DISTINCT etapa: 1.487 ganhas e 773 perdidas. Um CASE escrito
--    de memoria daria zero em toda linha, sem erro nenhum.
-- =====================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.vendedores AS
SELECT
  CAST(vendedor_id AS INT) AS vendedor_id,
  initcap(regexp_replace(trim(nome), '\\s+', ' ')) AS nome,
  nullif(trim(regiao), '') AS regiao,
  nullif(trim(uf), '')     AS uf,
  coalesce(try_to_date(trim(data_admissao)),
           try_to_date(trim(data_admissao), 'dd/MM/yyyy')) AS data_admissao,
  coalesce(try_to_date(trim(data_desligamento)),
           try_to_date(trim(data_desligamento), 'dd/MM/yyyy')) AS data_desligamento,
  try_cast(trim(meta_mensal) AS DECIMAL(18,2)) AS meta_mensal,
  -- ativo derivado da ausencia de desligamento: e' o unico sinal que a
  -- origem da'.
  coalesce(try_to_date(trim(data_desligamento)),
           try_to_date(trim(data_desligamento), 'dd/MM/yyyy')) IS NULL AS ativo,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.vendedores) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.vendedores;

COMMENT ON TABLE lakehouse_rotaperfume.silver.vendedores IS
  'Equipe comercial. ativo e derivado da ausencia de data_desligamento -- unico sinal disponivel na origem.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.vendedores.ativo IS
  'Vendedor sem data de desligamento. Vendedor desligado ainda aparece em carteira e em pedidos historicos.';

-- =====================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.carteira AS
WITH base AS (
  SELECT
    CAST(c.carteira_id AS INT) AS carteira_id,
    CAST(c.cliente_id AS INT)  AS cliente_id,
    CAST(c.vendedor_id AS INT) AS vendedor_id,
    coalesce(try_to_date(trim(c.data_inicio)),
             try_to_date(trim(c.data_inicio), 'dd/MM/yyyy')) AS data_inicio,
    coalesce(try_to_date(trim(c.data_fim)),
             try_to_date(trim(c.data_fim), 'dd/MM/yyyy'))    AS data_fim,
    v.data_desligamento
  FROM lakehouse_rotaperfume.bronze.carteira c
  LEFT JOIN lakehouse_rotaperfume.silver.vendedores v
         ON v.vendedor_id = CAST(c.vendedor_id AS INT)
)
SELECT
  carteira_id,
  cliente_id,
  vendedor_id,
  data_inicio,
  data_fim,
  -- vigente respeita as DUAS datas: a carteira pode estar aberta e o
  -- vendedor ja' ter saido da empresa.
  (data_fim IS NULL) AND (data_desligamento IS NULL) AS vigente,
  -- e aqui o problema fica visivel em vez de ser apagado
  (data_fim IS NULL) AND (data_desligamento IS NOT NULL) AS orfao_vendedor_desligado,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.carteira) AS _linhas_origem
FROM base;

COMMENT ON TABLE lakehouse_rotaperfume.silver.carteira IS
  'Atribuicao de clientes a vendedores. O dado NAO foi corrigido: 441 carteiras seguem abertas sob vendedor desligado, e a coluna orfao_vendedor_desligado expoe isso.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.carteira.vigente IS
  'Carteira realmente valida hoje: sem data_fim E com vendedor ainda na empresa. Carteira sem data_fim de vendedor desligado NAO e vigente.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.carteira.orfao_vendedor_desligado IS
  'Carteira aberta cujo vendedor foi desligado (441 casos). Problema de processo exposto de proposito: sao clientes sem responsavel comercial.';

-- =====================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.oportunidades AS
SELECT
  CAST(oportunidade_id AS INT) AS oportunidade_id,
  CAST(cliente_id AS INT)      AS cliente_id,
  CAST(vendedor_id AS INT)     AS vendedor_id,
  nullif(trim(origem), '')     AS origem,
  coalesce(try_to_date(trim(data_abertura)),
           try_to_date(trim(data_abertura), 'dd/MM/yyyy')) AS data_abertura,
  nullif(trim(etapa), '')      AS etapa,
  try_cast(trim(probabilidade_pct) AS DECIMAL(9,4)) AS probabilidade_pct,
  try_cast(trim(valor_estimado) AS DECIMAL(18,2))   AS valor_estimado,
  coalesce(try_to_date(trim(data_fechamento)),
           try_to_date(trim(data_fechamento), 'dd/MM/yyyy')) AS data_fechamento,
  try_cast(trim(ciclo_dias) AS INT) AS ciclo_dias,
  nullif(trim(motivo_perda), '')    AS motivo_perda,
  -- os valores REAIS da origem, conferidos com SELECT DISTINCT etapa
  trim(etapa) = 'Fechado ganho'   AS ganha,
  trim(etapa) = 'Fechado perdido' AS perdida,
  trim(etapa) NOT IN ('Fechado ganho', 'Fechado perdido') AS em_aberto,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.oportunidades) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.oportunidades;

COMMENT ON TABLE lakehouse_rotaperfume.silver.oportunidades IS
  'Funil comercial. As etapas de fechamento na origem sao Fechado ganho e Fechado perdido -- nao Ganha/Perdida.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.oportunidades.ganha IS
  'Oportunidade fechada com ganho (etapa = Fechado ganho na origem, 1.487 casos).';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.oportunidades.em_aberto IS
  'Oportunidade que ainda nao chegou a uma etapa de fechamento: prospeccao, qualificacao, proposta ou negociacao.';

-- =====================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.visitas AS
SELECT
  CAST(visita_id AS INT)   AS visita_id,
  CAST(cliente_id AS INT)  AS cliente_id,
  CAST(vendedor_id AS INT) AS vendedor_id,
  coalesce(try_to_date(trim(data_visita)),
           try_to_date(trim(data_visita), 'dd/MM/yyyy')) AS data_visita,
  nullif(trim(resultado), '') AS resultado,
  try_cast(trim(duracao_min) AS INT) AS duracao_min,
  trim(resultado) = 'Com pedido' AS gerou_pedido,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.visitas) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.visitas;

COMMENT ON TABLE lakehouse_rotaperfume.silver.visitas IS
  'Visitas comerciais tipadas, com a conversao em pedido sinalizada.';

-- =====================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.pagamentos AS
WITH base AS (
  SELECT
    CAST(pagamento_id AS INT) AS pagamento_id,
    CAST(pedido_id AS INT)    AS pedido_id,
    nullif(trim(forma_pagamento), '') AS forma_pagamento,
    try_cast(trim(parcelas) AS INT)   AS parcelas,
    try_cast(trim(valor) AS DECIMAL(18,2))         AS valor,
    try_cast(trim(taxa_pct) AS DECIMAL(9,4))       AS taxa_pct,
    try_cast(trim(valor_liquido) AS DECIMAL(18,2)) AS valor_liquido,
    coalesce(try_to_date(trim(data_vencimento)),
             try_to_date(trim(data_vencimento), 'dd/MM/yyyy')) AS data_vencimento,
    coalesce(try_to_date(trim(data_pagamento)),
             try_to_date(trim(data_pagamento), 'dd/MM/yyyy'))  AS data_pagamento,
    nullif(trim(status_pagamento), '') AS status_pagamento
  FROM lakehouse_rotaperfume.bronze.pagamentos
)
SELECT
  base.*,
  data_pagamento IS NOT NULL AS pago,
  -- atraso so' existe depois de pago; em aberto o atraso ainda esta correndo
  CASE WHEN data_pagamento IS NOT NULL
       THEN datediff(data_pagamento, data_vencimento) END AS dias_atraso,
  coalesce(valor - valor_liquido, CAST(0 AS DECIMAL(18,2))) AS custo_taxa,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.pagamentos) AS _linhas_origem
FROM base;

COMMENT ON TABLE lakehouse_rotaperfume.silver.pagamentos IS
  'Recebimentos tipados, com atraso calculado e custo de taxa isolado.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.pagamentos.dias_atraso IS
  'Dias entre vencimento e pagamento, negativo quando pago adiantado. NULO enquanto nao pago -- o atraso ainda esta correndo e fecha-lo em zero mascararia a inadimplencia.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.pagamentos.custo_taxa IS
  'Diferenca entre valor e valor liquido: o que a operadora reteve.';

-- =====================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.estoque AS
SELECT
  coalesce(try_to_date(trim(data_snapshot)),
           try_to_date(trim(data_snapshot), 'dd/MM/yyyy')) AS data_snapshot,
  trim(sku) AS sku,
  try_cast(trim(saldo) AS INT) AS saldo,
  -- derivada do saldo, nao copiada da origem: a regra fica escrita aqui,
  -- uma vez, e nao depende do flag que o ERP mandou.
  try_cast(trim(saldo) AS INT) = 0 AS ruptura,
  upper(trim(ruptura)) = 'S' AS ruptura_origem,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.estoque) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.estoque;

COMMENT ON TABLE lakehouse_rotaperfume.silver.estoque IS
  'Snapshots diarios de saldo por SKU, com ruptura derivada do saldo.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.estoque.ruptura IS
  'Saldo zerado no snapshot. Derivada de saldo = 0 e nao copiada da origem: a regra fica escrita uma vez, aqui.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.estoque.ruptura_origem IS
  'Flag de ruptura como o ERP mandou. Mantida ao lado da derivada para que divergencias entre as duas fiquem visiveis.';
