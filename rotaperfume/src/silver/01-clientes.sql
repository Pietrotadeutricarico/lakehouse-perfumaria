-- =====================================================================
-- silver.clientes -- a limpeza que NAO pode mudar o faturamento
-- =====================================================================
-- Tres decisoes moram aqui, e cada uma esta comentada onde acontece:
--   1. CNPJ normalizado para 14 digitos, NUNCA convertido para numero.
--   2. data_cadastro vem em dois formatos no mesmo campo.
--   3. 40 CNPJs tem dois cadastros -- e DISTINCT nao resolve, porque o
--      cliente_id e' diferente em cada um.
--
-- ANSI mode esta LIGADO neste workspace: to_date() sobre data malformada
-- ABORTA a query com CAST_INVALID_INPUT, nao devolve NULL. Por isso
-- try_to_date() em toda conversao de data, sempre.
-- =====================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.clientes AS
WITH base AS (
  SELECT
    CAST(cliente_id AS INT) AS cliente_id,
    -- CNPJ vem em tres formatos: puro, pontuado e com espaco em volta.
    -- trim -> tira nao-digito -> lpad com zero a esquerda. O lpad e' o que
    -- devolve o zero que 309 clientes tem e que qualquer CAST numerico
    -- apagaria em silencio.
    lpad(regexp_replace(trim(cnpj), '[^0-9]', ''), 14, '0') AS cnpj,
    -- caixa e espacamento inconsistentes: initcap padroniza, e o
    -- regexp colapsa espaco duplo que sobrou da digitacao na origem.
    initcap(regexp_replace(trim(razao_social), '\\s+', ' ')) AS razao_social,
    nullif(trim(segmento), '') AS segmento,
    nullif(trim(cidade), '')   AS cidade,
    nullif(trim(uf), '')       AS uf,
    nullif(trim(bairro), '')   AS bairro,
    -- ISO e dd/MM/yyyy misturados no MESMO campo. O coalesce dos dois
    -- try_to_date nao deixa nenhuma data para tras.
    coalesce(
      try_to_date(trim(data_cadastro)),
      try_to_date(trim(data_cadastro), 'dd/MM/yyyy')
    ) AS data_cadastro,
    CASE WHEN upper(trim(ativo)) = 'S' THEN true
         WHEN upper(trim(ativo)) = 'N' THEN false END AS ativo
  FROM lakehouse_rotaperfume.bronze.clientes
),
ordenado AS (
  SELECT
    b.*,
    -- Deduplicar NAO e' DISTINCT: os 40 CNPJs repetidos tem cliente_id
    -- diferente, entao DISTINCT devolveria as 80 linhas achando que sao
    -- clientes diferentes. row_number por CNPJ mantendo o mais antigo.
    --
    -- DESEMPATE POR cliente_id, e isso NAO e' detalhe: medimos que os 40
    -- pares tem data_cadastro IDENTICA. Sem o segundo criterio o
    -- row_number seria nao-deterministico e cada execucao manteria um id
    -- diferente. O menor cliente_id e' sempre o cadastro original.
    row_number() OVER (PARTITION BY b.cnpj ORDER BY b.data_cadastro, b.cliente_id) AS ordem,
    collect_list(b.cliente_id) OVER (PARTITION BY b.cnpj) AS ids_do_cnpj
  FROM base b
)
SELECT
  cliente_id,
  cnpj,
  razao_social,
  segmento,
  cidade,
  uf,
  bairro,
  data_cadastro,
  ativo,
  -- os ids descartados nao somem: os pedidos antigos continuam apontando
  -- para eles, e sem isso a rastreabilidade quebraria.
  array_sort(array_remove(ids_do_cnpj, cliente_id)) AS cliente_ids_duplicados,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.clientes) AS _linhas_origem
FROM ordenado
WHERE ordem = 1;

-- ---------------------------------------------------------------------
-- COMMENT: o que exigiu decisao
-- ---------------------------------------------------------------------
COMMENT ON TABLE lakehouse_rotaperfume.silver.clientes IS
  'Clientes limpos, tipados e deduplicados por CNPJ. 3.040 cadastros na bronze viram 3.000 clientes unicos: 40 CNPJs tinham dois cadastros com cliente_id diferente.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.clientes.cnpj IS
  'CNPJ normalizado para 14 digitos (trim, remocao de pontuacao, lpad com zero a esquerda). Mantido como texto de proposito: converter para numero apaga o zero a esquerda de 309 clientes.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.clientes.razao_social IS
  'Razao social padronizada com initcap e espaco duplo colapsado. Na origem vinha em caixa alta, caixa baixa e mista.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.clientes.data_cadastro IS
  'Data de cadastro. Na origem vinha em ISO e em dd/MM/yyyy no mesmo campo, convertida com coalesce de dois try_to_date.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.clientes.cliente_ids_duplicados IS
  'cliente_id dos cadastros descartados na deduplicacao deste CNPJ. Vazio quando o cliente nao tinha duplicata. Os pedidos antigos ainda apontam para esses ids.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.clientes._linhas_origem IS
  'Linhas lidas da bronze (3.040). A diferenca para o COUNT desta tabela e a deduplicacao.';

-- ---------------------------------------------------------------------
-- O CONTRATO: quem recusa a escrita errada e' a tabela, nao o script.
-- DROP antes do ADD para o arquivo ser idempotente em re-execucao.
-- ---------------------------------------------------------------------
ALTER TABLE lakehouse_rotaperfume.silver.clientes DROP CONSTRAINT IF EXISTS cnpj_14_digitos;
ALTER TABLE lakehouse_rotaperfume.silver.clientes
  ADD CONSTRAINT cnpj_14_digitos CHECK (length(cnpj) = 14);

ALTER TABLE lakehouse_rotaperfume.silver.clientes DROP CONSTRAINT IF EXISTS data_cadastro_obrigatoria;
ALTER TABLE lakehouse_rotaperfume.silver.clientes
  ADD CONSTRAINT data_cadastro_obrigatoria CHECK (data_cadastro IS NOT NULL);
