-- =====================================================================
-- gold.fato_vendas -- O CONTRATO, escrito ANTES do SQL
-- =====================================================================
-- GRANULARIDADE
--   Uma linha por ITEM de pedido. Se voce contar linhas, esta contando
--   itens, nao pedidos. COUNT(DISTINCT pedido_id) da' pedidos.
--
-- FILTRO
--   Exclui pedido CANCELADO (957 pedidos, ~6.644 itens).
--   NAO exclui DEVOLUCAO. Ela entra com quantidade e receita NEGATIVAS.
--
-- DIMENSOES
--   data_pedido, ano, mes, canal, cliente_id, razao_social, segmento,
--   cidade, vendedor_id, sku, categoria, marca, nota_olfativa
--
-- METRICAS
--   quantidade, preco_praticado, receita, custo, margem, devolucao
--   receita = quantidade * preco_praticado
--   custo   = quantidade * custo_unitario do produto
--   margem  = receita - custo
--
-- POR QUE A DEVOLUCAO FICA DENTRO
--   Se ela ficasse de fora, a gold somaria R$ 103.568.586,35 e a silver
--   R$ 102.303.828,05 -- R$ 1,26 milhao de diferenca entre duas camadas do
--   MESMO pipeline, e ninguem saberia qual das duas esta certa.
--   Quem quiser o bruto pede explicitamente:
--     SELECT SUM(receita) FILTER (WHERE NOT devolucao) FROM gold.fato_vendas
--
-- ESPERADO: 191.080 linhas, SUM(receita) = 102.303.828,05
-- =====================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.fato_vendas
USING DELTA
PARTITIONED BY (ano, mes)
AS
SELECT
  -- chaves
  i.item_id,
  i.pedido_id,
  -- dimensoes de tempo e canal
  p.data_pedido,
  p.canal,
  -- dimensoes de cliente
  p.cliente_id,
  c.razao_social,
  c.segmento,
  c.cidade,
  -- dimensao de vendedor
  p.vendedor_id,
  -- dimensoes de produto
  i.sku,
  pr.categoria,
  pr.marca,
  pr.nota_olfativa,
  -- metricas. quantidade e receita carregam o SINAL: negativo em devolucao.
  i.quantidade,
  i.preco_praticado,
  CAST(i.quantidade * i.preco_praticado AS DECIMAL(18,2))              AS receita,
  CAST(i.quantidade * pr.custo_unitario AS DECIMAL(18,2))              AS custo,
  CAST(i.quantidade * (i.preco_praticado - pr.custo_unitario) AS DECIMAL(18,2)) AS margem,
  i.devolucao,
  i.sku_descontinuado,
  current_timestamp() AS _processado_em,
  -- particionamento por ultimo, como o PARTITIONED BY exige
  p.ano,
  p.mes
FROM lakehouse_rotaperfume.silver.itens_pedido i
-- INNER JOIN com pedidos: e' ele que aplica o filtro de cancelado.
JOIN lakehouse_rotaperfume.silver.pedidos p
  ON p.pedido_id = i.pedido_id
 AND NOT p.cancelado
-- LEFT nas dimensoes: um cadastro faltante NAO pode sumir com a venda.
-- Perder linha aqui mudaria o faturamento, que e' exatamente o que o
-- teste 1 existe para impedir.
LEFT JOIN lakehouse_rotaperfume.silver.produtos pr ON pr.sku = i.sku
LEFT JOIN lakehouse_rotaperfume.silver.clientes c  ON c.cliente_id = p.cliente_id;

-- ---------------------------------------------------------------------
-- COMMENT de NEGOCIO, nao tecnico. E' o que o Genie le na entrega 6 para
-- escolher a coluna certa: coluna sem comentario e' coluna que ele usa
-- errado, com confianca.
-- ---------------------------------------------------------------------
COMMENT ON TABLE lakehouse_rotaperfume.gold.fato_vendas IS
  'Vendas no grao de item de pedido. Exclui pedidos cancelados e INCLUI devolucoes com valor negativo. SUM(receita) reproduz o faturamento da silver: R$ 102.303.828,05.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.fato_vendas.quantidade IS
  'Unidades vendidas. NEGATIVA quando o item e uma devolucao, para que a soma da coluna ja resulte no volume liquido.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.fato_vendas.preco_praticado IS
  'Preco efetivamente cobrado por unidade, ja com o desconto comercial aplicado. Diferente do preco de tabela em dim_produto.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.fato_vendas.receita IS
  'Receita liquida do item: quantidade vezes preco praticado. Negativa em devolucoes. Some esta coluna para obter o faturamento da empresa. Para o bruto vendido, use SUM(receita) FILTER (WHERE NOT devolucao).';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.fato_vendas.custo IS
  'Custo do produto vendido: quantidade vezes custo unitario do catalogo. Nao inclui frete, comissao nem custo de estrutura.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.fato_vendas.margem IS
  'Receita menos custo do produto. Nao considera desconto comercial adicional, frete, comissao nem impostos. E a definicao unica de margem da empresa.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.fato_vendas.devolucao IS
  'Item devolvido pelo cliente. A linha permanece no fato com valores negativos: retira-la inflaria o faturamento em R$ 1,26 milhao.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.fato_vendas.sku_descontinuado IS
  'A venda ocorreu, mas o produto ja saiu de linha. Util para nao planejar reposicao sobre historico de item descontinuado.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.fato_vendas.canal IS
  'Canal por onde o pedido entrou (visita do vendedor, telefone, WhatsApp, e-commerce).';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.fato_vendas.segmento IS
  'Segmento do cliente que comprou (loja de shopping, farmacia, distribuidor, e-commerce).';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.fato_vendas.data_pedido IS
  'Data em que o pedido foi feito. A base cobre de 2024-09-01 a 2026-08-31.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.fato_vendas.ano IS
  'Ano do pedido. Coluna de particionamento.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.fato_vendas.mes IS
  'Mes do pedido, de 1 a 12. Coluna de particionamento. Abril, junho e outubro sao os meses de pico do setor.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.fato_vendas.pedido_id IS
  'Pedido ao qual o item pertence. Use COUNT(DISTINCT pedido_id) para contar pedidos: cada linha desta tabela e um ITEM, nao um pedido.';
