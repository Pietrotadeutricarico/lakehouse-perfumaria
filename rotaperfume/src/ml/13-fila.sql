-- =====================================================================
-- gold.fila_semanal -- o ultimo metro
-- =====================================================================
-- Score nao e' decisao. 0,8412 nao e' uma acao: entregue isso ao vendedor e
-- ele volta a ligar pela intuicao na segunda-feira. E' aqui que os projetos
-- de ML morrem -- nao no algoritmo.
--
-- A FILA E' GLOBAL, A CAPACIDADE E' QUE E' POR PESSOA.
-- A tentacao e' dar 5 clientes para cada um dos 42 vendedores, "que e' mais
-- justo". Justo com quem? Se a carteira do Joao esta quente e a do Pedro
-- esta fria, a cota igual obriga o Joao a deixar cliente quente na mesa
-- para o Pedro ligar para cliente frio. Por isso: ORDER BY score DESC
-- LIMIT 200, e a numeracao por vendedor vem DEPOIS.
--
-- A ORDEM DAS OPERACOES E' O ERRO FACIL DESTE ARQUIVO:
--   1o  juntar a carteira e DESCARTAR quem nao e' elegivel
--   2o  ORDER BY score DESC LIMIT 200
--   3o  ROW_NUMBER() OVER (PARTITION BY vendedor)
-- Se o descarte vier DEPOIS do LIMIT, a fila sai com ~172 linhas: seis dos
-- 42 vendedores estao desligados e levam os clientes deles junto. E' a
-- sujeira no 9 da silver cobrando o preco dela.
-- =====================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.fila_semanal AS
WITH corte AS (
  -- a data de referencia vem do proprio score, nunca de current_date()
  SELECT MIN(_referencia) AS referencia
  FROM lakehouse_rotaperfume.gold.score_propensao
),

-- 1o PASSO: elegibilidade. Vendedor desligado nao recebe ligacao para fazer.
elegiveis AS (
  SELECT
    s.cliente_id, s.score, s.faixa, s.versao_modelo, s._referencia,
    v.nome AS vendedor
  FROM lakehouse_rotaperfume.gold.score_propensao s
  JOIN lakehouse_rotaperfume.silver.carteira c
    ON c.cliente_id = s.cliente_id
   AND c.vigente
   AND NOT c.orfao_vendedor_desligado
  JOIN lakehouse_rotaperfume.silver.vendedores v
    ON v.vendedor_id = c.vendedor_id
),

-- 2o PASSO: so' agora o corte dos 200
top200 AS (
  SELECT * FROM elegiveis ORDER BY score DESC LIMIT 200
),

-- limiar de "cliente grande", calculado do dado e nao chutado
limiar AS (
  SELECT PERCENTILE(valor_total, 0.9) AS p90
  FROM lakehouse_rotaperfume.gold.features_cliente
),

-- marca preferida: a que mais gerou receita para aquele cliente
marca_preferida AS (
  SELECT cliente_id, marca FROM (
    SELECT cliente_id, marca,
           ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY SUM(receita) DESC) AS rn
    FROM lakehouse_rotaperfume.gold.fato_vendas
    GROUP BY cliente_id, marca
  ) WHERE rn = 1
),

-- o que ele comprou nos ultimos 90 dias: e' o que NAO se sugere
comprou_recente AS (
  SELECT DISTINCT f.cliente_id, f.sku
  FROM lakehouse_rotaperfume.gold.fato_vendas f
  CROSS JOIN corte
  WHERE f.data_pedido >= date_sub(corte.referencia, 90)
),

-- o SKU mais comprado na marca preferida que ele parou de comprar
candidato AS (
  SELECT cliente_id, sku FROM (
    SELECT f.cliente_id, f.sku,
           ROW_NUMBER() OVER (
             PARTITION BY f.cliente_id ORDER BY SUM(f.quantidade) DESC, f.sku
           ) AS rn
    FROM lakehouse_rotaperfume.gold.fato_vendas f
    JOIN marca_preferida m
      ON m.cliente_id = f.cliente_id AND m.marca = f.marca
    WHERE NOT EXISTS (
      SELECT 1 FROM comprou_recente r
      WHERE r.cliente_id = f.cliente_id AND r.sku = f.sku
    )
    GROUP BY f.cliente_id, f.sku
  ) WHERE rn = 1
),

-- snapshot MAIS RECENTE de estoque: a tabela e' um retrato semanal, nao um
-- historico para somar. Somar daria estoque multiplicado por 105 semanas.
estoque_atual AS (
  SELECT e.sku, e.saldo
  FROM lakehouse_rotaperfume.silver.estoque e
  WHERE e.data_snapshot = (
    SELECT MAX(data_snapshot) FROM lakehouse_rotaperfume.silver.estoque
  )
)

SELECT
  t.vendedor,
  ROW_NUMBER() OVER (PARTITION BY t.vendedor ORDER BY t.score DESC) AS ordem,
  t.cliente_id,
  d.razao_social,
  d.cidade,
  d.uf,
  ROUND(t.score, 4) AS score,
  t.faixa,
  ROUND(f.ticket_medio, 2) AS ticket_medio,

  -- MOTIVO: do sinal mais RARO para o mais comum. Invertida, a condicao
  -- mais comum come todas as outras.
  --
  -- MEDIDO nos 200 desta fila, e e' por isso que a ordem e' esta:
  --   atraso > 3 ......... 0 clientes
  --   atraso > 1.5 ....... 6
  --   cliente grande ..... 68
  --   comprou lancamento . 172   <- o mais comum vem por ULTIMO
  -- Na primeira versao o lancamento veio antes do cliente grande e 167 dos
  -- 200 sairam com a mesma frase. Se mudar a ordem, meca antes.
  --
  -- O ELSE e' obrigatorio: motivo nulo quebra o teste 2.
  CASE
    WHEN f.atraso_relativo > 3 THEN concat(
      'Compra a cada ', FORMAT_NUMBER(f.intervalo_medio_dias, 0),
      ' dias e esta ha ', FORMAT_NUMBER(f.recencia_dias, 0),
      ' sem pedido. Risco de perder para o concorrente.')
    WHEN f.atraso_relativo > 1.5 THEN concat(
      'Esta ', translate(FORMAT_NUMBER(f.atraso_relativo, 1), ',.', '.,'),
      ' vezes mais atrasado que o ritmo dele.')
    WHEN f.valor_total >= l.p90 THEN concat(
      'Cliente grande, R$ ', translate(FORMAT_NUMBER(f.valor_total, 2), ',.', '.,'),
      ' no periodo. Manter proximo.')
    WHEN f.comprou_lancamento = 1 THEN
      'Comprou lancamento recente. Alta chance de repetir.'
    ELSE 'Dentro do ritmo. Contato de manutencao.'
  END AS motivo,

  -- SUGESTAO: LEFT JOIN no estoque de proposito. O snapshot mais recente
  -- cobre 80 dos 292 SKUs, entao exigir saldo apagaria quase toda sugestao.
  CASE
    WHEN c.sku IS NULL THEN 'Sem sugestao: cliente sem historico na marca preferida.'
    WHEN e.saldo IS NULL THEN concat(c.sku, ' (sem leitura de estoque nesta semana)')
    WHEN e.saldo = 0 THEN concat(c.sku, ' -- ATENCAO: sem saldo em estoque')
    ELSE concat(c.sku, ' (', translate(FORMAT_NUMBER(e.saldo, 0), ',', '.'), ' em estoque)')
  END AS sugestao,

  t.versao_modelo,
  t._referencia,
  current_timestamp() AS _processado_em
FROM top200 t
JOIN lakehouse_rotaperfume.gold.dim_cliente d ON d.cliente_id = t.cliente_id
JOIN lakehouse_rotaperfume.gold.features_cliente f ON f.cliente_id = t.cliente_id
CROSS JOIN limiar l
LEFT JOIN candidato c ON c.cliente_id = t.cliente_id
LEFT JOIN estoque_atual e ON e.sku = c.sku;

-- ---------------------------------------------------------------------
-- COMMENT na tabela E em todas as colunas: e' o comentario de coluna que um
-- agente le para responder sem inventar.
-- ---------------------------------------------------------------------
COMMENT ON TABLE lakehouse_rotaperfume.gold.fila_semanal IS
  'As 200 ligacoes da semana, em ordem de propensao de compra. A fila e global e a capacidade e por vendedor: clientes sem carteira vigente ou de vendedor desligado ficam fora antes do corte dos 200.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.fila_semanal.vendedor IS
  'Nome do vendedor responsavel pela carteira do cliente. Vendedores desligados nao aparecem.';
COMMENT ON COLUMN lakehouse_rotaperfume.gold.fila_semanal.ordem IS
  'Posicao do cliente dentro da fila DAQUELE vendedor, do maior score para o menor. Comece pelo 1.';
COMMENT ON COLUMN lakehouse_rotaperfume.gold.fila_semanal.cliente_id IS
  'Identificador do cliente no catalogo.';
COMMENT ON COLUMN lakehouse_rotaperfume.gold.fila_semanal.razao_social IS
  'Nome do cliente, como falar com ele.';
COMMENT ON COLUMN lakehouse_rotaperfume.gold.fila_semanal.cidade IS
  'Cidade do cliente.';
COMMENT ON COLUMN lakehouse_rotaperfume.gold.fila_semanal.uf IS
  'Estado do cliente.';
COMMENT ON COLUMN lakehouse_rotaperfume.gold.fila_semanal.score IS
  'Probabilidade estimada de o cliente comprar nos proximos 7 dias, de 0 a 1. Vem do modelo propensao_compra.';
COMMENT ON COLUMN lakehouse_rotaperfume.gold.fila_semanal.faixa IS
  'Faixa do score: Fria, Morna, Quente ou Muito quente. Serve para conversar sem citar numero.';
COMMENT ON COLUMN lakehouse_rotaperfume.gold.fila_semanal.ticket_medio IS
  'Valor medio dos pedidos deste cliente, em reais. Ajuda a dimensionar a oferta.';
COMMENT ON COLUMN lakehouse_rotaperfume.gold.fila_semanal.motivo IS
  'Por que este cliente esta na fila, em portugues e com os numeros dele. E o que faz o vendedor confiar quando o modelo acerta e entender quando erra.';
COMMENT ON COLUMN lakehouse_rotaperfume.gold.fila_semanal.sugestao IS
  'O que oferecer: o SKU mais comprado na marca preferida do cliente que ele parou de comprar nos ultimos 90 dias, com o saldo do snapshot mais recente.';
COMMENT ON COLUMN lakehouse_rotaperfume.gold.fila_semanal.versao_modelo IS
  'Versao do modelo no Unity Catalog que gerou o score. Serve para auditar uma fila antiga.';
COMMENT ON COLUMN lakehouse_rotaperfume.gold.fila_semanal._referencia IS
  'Data de corte usada para calcular as features. Tudo na linha e anterior a esta data.';

-- =====================================================================
-- AS QUATRO FERRAMENTAS
-- =====================================================================
-- Nao e' endpoint, nao e' framework e nao tem prompt: sao funcoes no
-- catalogo, com contrato e COMMENT. O agente so' sabe chamar -- e e' o
-- COMMENT que diz a ele QUANDO usar cada uma.
--
-- Todo parametro com prefixo p_: parametro com o mesmo nome de uma coluna
-- fica ambiguo dentro do corpo e o CREATE FUNCTION falha.
-- =====================================================================

CREATE OR REPLACE FUNCTION lakehouse_rotaperfume.gold.priorizar_carteira(
  p_vendedor STRING COMMENT 'Nome do vendedor, como aparece na coluna vendedor da fila',
  p_quantos INT COMMENT 'Quantos clientes devolver, do topo da fila dele'
)
RETURNS TABLE (
  ordem INT, cliente_id INT, razao_social STRING, cidade STRING,
  score DOUBLE, faixa STRING, motivo STRING, sugestao STRING
)
COMMENT 'Devolve os proximos clientes que um vendedor deve contatar nesta semana, em ordem de prioridade, com o motivo e o que oferecer. Use quando perguntarem para quem ligar, quem contatar ou qual a lista da semana de alguem.'
RETURN
  SELECT CAST(f.ordem AS INT), f.cliente_id, f.razao_social, f.cidade,
         f.score, f.faixa, f.motivo, f.sugestao
  FROM lakehouse_rotaperfume.gold.fila_semanal f
  WHERE f.vendedor = p_vendedor
    -- nunca LIMIT p_quantos: o Databricks exige LIMIT constante e o erro e
    -- INVALID_LIMIT_LIKE_EXPRESSION. A fila ja vem numerada, entao filtra-se.
    AND f.ordem <= p_quantos
  ORDER BY f.ordem;

CREATE OR REPLACE FUNCTION lakehouse_rotaperfume.gold.contexto_cliente(
  p_cliente_id INT COMMENT 'Identificador do cliente'
)
RETURNS TABLE (
  razao_social STRING, cidade STRING, segmento STRING,
  pedidos BIGINT, receita_total DOUBLE, ticket_medio DOUBLE,
  ultima_compra DATE, dias_sem_comprar INT, marcas_preferidas STRING
)
COMMENT 'Devolve o historico resumido de um cliente: quanto ja comprou, ticket medio, quando comprou pela ultima vez e as marcas que ele mais leva. Use antes de uma ligacao, para saber com quem se esta falando.'
RETURN
  SELECT
    max(d.razao_social), max(d.cidade), max(d.segmento),
    count(DISTINCT v.pedido_id),
    CAST(sum(v.receita) AS DOUBLE),
    CAST(sum(v.receita) / nullif(count(DISTINCT v.pedido_id), 0) AS DOUBLE),
    max(v.data_pedido),
    CAST(datediff(
      (SELECT MIN(_referencia) FROM lakehouse_rotaperfume.gold.score_propensao),
      max(v.data_pedido)) AS INT),
    concat_ws(', ', array_sort(collect_set(v.marca)))
  FROM lakehouse_rotaperfume.gold.fato_vendas v
  JOIN lakehouse_rotaperfume.gold.dim_cliente d ON d.cliente_id = v.cliente_id
  WHERE v.cliente_id = p_cliente_id;

CREATE OR REPLACE FUNCTION lakehouse_rotaperfume.gold.sugerir_produtos(
  p_cliente_id INT COMMENT 'Identificador do cliente'
)
RETURNS TABLE (
  sku STRING, descricao STRING, marca STRING,
  ja_comprou_unidades BIGINT, ultima_compra DATE, dias_sem_comprar INT
)
COMMENT 'Devolve os produtos que o cliente costumava comprar e parou de comprar nos ultimos 90 dias, do mais comprado para o menos. Use para montar a oferta de uma ligacao.'
RETURN
  SELECT v.sku, max(p.descricao), max(v.marca),
         CAST(sum(v.quantidade) AS BIGINT), max(v.data_pedido),
         CAST(datediff(
           (SELECT MIN(_referencia) FROM lakehouse_rotaperfume.gold.score_propensao),
           max(v.data_pedido)) AS INT)
  FROM lakehouse_rotaperfume.gold.fato_vendas v
  LEFT JOIN lakehouse_rotaperfume.gold.dim_produto p ON p.sku = v.sku
  WHERE v.cliente_id = p_cliente_id
  GROUP BY v.sku
  HAVING max(v.data_pedido) < date_sub(
    (SELECT MIN(_referencia) FROM lakehouse_rotaperfume.gold.score_propensao), 90)
  ORDER BY sum(v.quantidade) DESC;

CREATE OR REPLACE FUNCTION lakehouse_rotaperfume.gold.checar_disponibilidade(
  p_sku STRING COMMENT 'Codigo do SKU, no formato SKU00001'
)
RETURNS TABLE (sku STRING, saldo INT, ruptura BOOLEAN, data_snapshot DATE)
COMMENT 'Devolve o saldo em estoque de um SKU no snapshot mais recente. Use antes de prometer prazo ou quantidade ao cliente. Se nao vier linha, aquele SKU nao foi lido no ultimo snapshot.'
RETURN
  SELECT e.sku, e.saldo, e.ruptura, e.data_snapshot
  FROM lakehouse_rotaperfume.silver.estoque e
  WHERE e.sku = p_sku
    AND e.data_snapshot = (
      SELECT MAX(data_snapshot) FROM lakehouse_rotaperfume.silver.estoque
    );

-- =====================================================================
-- OS TRES TESTES QUE QUEBRAM O JOB
-- =====================================================================

SELECT
  'teste 1 - a fila tem exatamente 200 linhas' AS teste,
  CAST(n AS STRING) AS calculado, '200' AS esperado,
  CASE WHEN n = 200 THEN 'PASSOU'
       ELSE raise_error(concat('TESTE 1 FALHOU: a fila tem ', CAST(n AS STRING),
         ' linhas. Se veio perto de 172, o descarte de vendedor desligado rodou ',
         'DEPOIS do LIMIT 200 -- filtre a elegibilidade antes de limitar.'))
  END AS resultado
FROM (SELECT COUNT(*) AS n FROM lakehouse_rotaperfume.gold.fila_semanal);

SELECT
  'teste 2 - nenhum motivo nulo ou vazio' AS teste,
  CAST(n AS STRING) AS calculado, '0' AS esperado,
  CASE WHEN n = 0 THEN 'PASSOU'
       ELSE raise_error(concat('TESTE 2 FALHOU: ', CAST(n AS STRING),
         ' linhas sem motivo. Falta o ELSE no CASE WHEN do motivo.'))
  END AS resultado
FROM (SELECT COUNT(*) AS n FROM lakehouse_rotaperfume.gold.fila_semanal
      WHERE motivo IS NULL OR trim(motivo) = '');

SELECT
  'teste 3 - nenhum score fora de [0, 1]' AS teste,
  CAST(n AS STRING) AS calculado, '0' AS esperado,
  CASE WHEN n = 0 THEN 'PASSOU'
       ELSE raise_error(concat('TESTE 3 FALHOU: ', CAST(n AS STRING),
         ' linhas com score fora do intervalo. O score e uma probabilidade.'))
  END AS resultado
FROM (SELECT COUNT(*) AS n FROM lakehouse_rotaperfume.gold.fila_semanal
      WHERE score < 0 OR score > 1);

-- Resumo: se chegou aqui, os tres passaram.
SELECT 'RESUMO' AS teste,
       COUNT(*) AS ligacoes,
       COUNT(DISTINCT vendedor) AS vendedores,
       ROUND(AVG(score), 3) AS score_medio,
       COUNT(DISTINCT motivo) AS motivos_distintos
FROM lakehouse_rotaperfume.gold.fila_semanal;
