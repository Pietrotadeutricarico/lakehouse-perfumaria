-- =====================================================================
-- Os 9 testes que PARAM o pipeline
-- =====================================================================
-- Teste que nao quebra o job nao e' teste, e' relatorio. Se a verificacao
-- falha e o pipeline segue, o dashboard mostra numero errado com cara de
-- certo -- e alguem descobre numa reuniao, tres meses depois.
--
-- MECANICA: raise_error() retorna o tipo NOTHING, entao ele nao pode ser
-- usado sozinho numa coluna. Vai dentro de CASE WHEN <ok> THEN 'PASSOU'
-- ELSE raise_error('...') END: quando a condicao falha, a tarefa aborta.
--
-- Se um teste falhar, corrija a TRANSFORMACAO -- nunca o teste.
-- =====================================================================

-- ---------------------------------------------------------------------
-- TESTE 1 -- o que mais importa: a limpeza NAO pode mudar o faturamento.
-- gold.fato_vendas tem que somar o mesmo que silver.pedidos.
-- ---------------------------------------------------------------------
SELECT
  'teste 1 - receita da gold igual a da silver'     AS teste,
  CAST(g.receita AS STRING)                         AS calculado,
  CAST(s.receita AS STRING)                         AS esperado,
  CASE WHEN abs(g.receita - s.receita) <= 0.01 THEN 'PASSOU'
       ELSE raise_error(concat(
         'TESTE 1 FALHOU: gold soma ', CAST(g.receita AS STRING),
         ' e silver soma ', CAST(s.receita AS STRING),
         '. A limpeza mudou o faturamento -- alguma linha foi descartada.'))
  END AS resultado
FROM (SELECT sum(receita) AS receita FROM lakehouse_rotaperfume.gold.fato_vendas) g
CROSS JOIN (SELECT sum(valor_liquido) AS receita FROM lakehouse_rotaperfume.silver.pedidos) s;

-- ---------------------------------------------------------------------
-- TESTE 2 -- a deduplicacao funcionou: um CNPJ, um cliente.
-- ---------------------------------------------------------------------
SELECT
  'teste 2 - CNPJ unico em silver.clientes' AS teste,
  CAST(duplicados AS STRING)                AS calculado,
  '0'                                       AS esperado,
  CASE WHEN duplicados = 0 THEN 'PASSOU'
       ELSE raise_error(concat('TESTE 2 FALHOU: ', CAST(duplicados AS STRING),
         ' CNPJ com mais de um cadastro. A deduplicacao nao rodou.'))
  END AS resultado
FROM (
  SELECT count(*) AS duplicados FROM (
    SELECT cnpj FROM lakehouse_rotaperfume.silver.clientes
    GROUP BY cnpj HAVING count(*) > 1)
);

-- ---------------------------------------------------------------------
-- TESTE 3 -- nenhuma data perdida na conversao dos dois formatos.
-- ---------------------------------------------------------------------
SELECT
  'teste 3 - nenhuma data_pedido nula' AS teste,
  CAST(nulas AS STRING)                AS calculado,
  '0'                                  AS esperado,
  CASE WHEN nulas = 0 THEN 'PASSOU'
       ELSE raise_error(concat('TESTE 3 FALHOU: ', CAST(nulas AS STRING),
         ' pedidos sem data. Alguma data nao casou com nenhum dos dois formatos.'))
  END AS resultado
FROM (SELECT count(*) AS nulas FROM lakehouse_rotaperfume.silver.pedidos
      WHERE data_pedido IS NULL);

-- ---------------------------------------------------------------------
-- TESTE 4 -- receita negativa so' pode existir onde ha devolucao.
-- Se aparecer em outro lugar, o sinal vazou para onde nao devia.
-- ---------------------------------------------------------------------
SELECT
  'teste 4 - receita negativa apenas em devolucao' AS teste,
  CAST(fora_de_lugar AS STRING)                    AS calculado,
  '0'                                              AS esperado,
  CASE WHEN fora_de_lugar = 0 THEN 'PASSOU'
       ELSE raise_error(concat('TESTE 4 FALHOU: ', CAST(fora_de_lugar AS STRING),
         ' itens com receita negativa que NAO sao devolucao.'))
  END AS resultado
FROM (SELECT count(*) AS fora_de_lugar FROM lakehouse_rotaperfume.gold.fato_vendas
      WHERE receita < 0 AND NOT devolucao);

-- ---------------------------------------------------------------------
-- TESTE 5 -- volume do fato dentro da faixa esperada.
-- Fora da faixa significa join duplicando linha ou filtro comendo linha.
-- ---------------------------------------------------------------------
SELECT
  'teste 5 - volume do fato entre 140.000 e 250.000' AS teste,
  CAST(linhas AS STRING)                             AS calculado,
  '140000 a 250000'                                  AS esperado,
  CASE WHEN linhas BETWEEN 140000 AND 250000 THEN 'PASSOU'
       ELSE raise_error(concat('TESTE 5 FALHOU: fato_vendas tem ',
         CAST(linhas AS STRING), ' linhas, fora da faixa esperada.'))
  END AS resultado
FROM (SELECT count(*) AS linhas FROM lakehouse_rotaperfume.gold.fato_vendas);

-- ---------------------------------------------------------------------
-- TESTE 6 -- integridade referencial: todo pedido do fato existe na silver.
-- ---------------------------------------------------------------------
SELECT
  'teste 6 - nenhum pedido_id orfao no fato' AS teste,
  CAST(orfaos AS STRING)                     AS calculado,
  '0'                                        AS esperado,
  CASE WHEN orfaos = 0 THEN 'PASSOU'
       ELSE raise_error(concat('TESTE 6 FALHOU: ', CAST(orfaos AS STRING),
         ' itens do fato apontam para pedido que nao existe na silver.'))
  END AS resultado
FROM (
  SELECT count(*) AS orfaos
  FROM lakehouse_rotaperfume.gold.fato_vendas f
  LEFT JOIN lakehouse_rotaperfume.silver.pedidos p ON p.pedido_id = f.pedido_id
  WHERE p.pedido_id IS NULL
);

-- ---------------------------------------------------------------------
-- TESTE 7 -- integridade referencial de cliente. Este teste protege
-- exatamente o risco da deduplicacao: se o fato carregasse um cliente_id
-- descartado na dedup, ele apareceria aqui.
-- ---------------------------------------------------------------------
SELECT
  'teste 7 - nenhum cliente_id orfao no fato' AS teste,
  CAST(orfaos AS STRING)                      AS calculado,
  '0'                                         AS esperado,
  CASE WHEN orfaos = 0 THEN 'PASSOU'
       ELSE raise_error(concat('TESTE 7 FALHOU: ', CAST(orfaos AS STRING),
         ' itens do fato apontam para cliente que nao existe na silver, provavelmente um cliente_id descartado na deduplicacao.'))
  END AS resultado
FROM (
  SELECT count(*) AS orfaos
  FROM lakehouse_rotaperfume.gold.fato_vendas f
  LEFT JOIN lakehouse_rotaperfume.silver.clientes c ON c.cliente_id = f.cliente_id
  WHERE c.cliente_id IS NULL
);

-- ---------------------------------------------------------------------
-- TESTE 8 -- CONFORMADO: o mart soma o mesmo que o fato.
-- E' este teste que da sentido a palavra: quatro tabelas, quatro
-- consumidores, o mesmo numero.
-- ---------------------------------------------------------------------
SELECT
  'teste 8 - mart_produto_performance soma igual ao fato' AS teste,
  CAST(m.receita AS STRING)                               AS calculado,
  CAST(f.receita AS STRING)                               AS esperado,
  CASE WHEN abs(m.receita - f.receita) <= 0.01 THEN 'PASSOU'
       ELSE raise_error(concat('TESTE 8 FALHOU: mart soma ',
         CAST(m.receita AS STRING), ' e fato soma ', CAST(f.receita AS STRING),
         '. Os marts deixaram de ser conformados.'))
  END AS resultado
FROM (SELECT sum(receita) AS receita FROM lakehouse_rotaperfume.gold.mart_produto_performance) m
CROSS JOIN (SELECT sum(receita) AS receita FROM lakehouse_rotaperfume.gold.fato_vendas) f;

-- ---------------------------------------------------------------------
-- TESTE 9 -- o CNPJ manteve os 14 digitos, incluindo o zero a esquerda
-- de 309 clientes.
-- ---------------------------------------------------------------------
SELECT
  'teste 9 - todo CNPJ com 14 digitos' AS teste,
  CAST(fora_do_padrao AS STRING)       AS calculado,
  '0'                                  AS esperado,
  CASE WHEN fora_do_padrao = 0 THEN 'PASSOU'
       ELSE raise_error(concat('TESTE 9 FALHOU: ', CAST(fora_do_padrao AS STRING),
         ' CNPJ sem 14 digitos. Alguem converteu CNPJ para numero.'))
  END AS resultado
FROM (SELECT count(*) AS fora_do_padrao FROM lakehouse_rotaperfume.silver.clientes
      WHERE length(cnpj) <> 14);

-- ---------------------------------------------------------------------
-- Resumo final: se chegou aqui, os 9 passaram.
-- ---------------------------------------------------------------------
SELECT
  'RESUMO' AS teste,
  (SELECT count(*) FROM lakehouse_rotaperfume.gold.fato_vendas)          AS linhas_fato,
  (SELECT round(sum(receita), 2) FROM lakehouse_rotaperfume.gold.fato_vendas) AS receita_liquida,
  (SELECT round(sum(receita), 2) FROM lakehouse_rotaperfume.gold.fato_vendas
     WHERE NOT devolucao)                                                AS bruto_vendido,
  (SELECT round(sum(margem), 2) FROM lakehouse_rotaperfume.gold.fato_vendas)  AS margem,
  '9 de 9 testes passaram' AS resultado;
