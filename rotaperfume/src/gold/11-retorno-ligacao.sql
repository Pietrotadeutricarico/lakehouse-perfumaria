-- =====================================================================
-- gold.retorno_ligacao -- a tabela que nasce vazia
-- =====================================================================
-- Tres noites construindo o caminho de IDA: o pipeline sabe a quem ligar.
-- E nunca fica sabendo o que aconteceu depois. Esta e' a primeira peca do
-- caminho de VOLTA, e ela comeca sem nenhuma linha.
--
-- POR QUE `IF NOT EXISTS` E NAO `CREATE OR REPLACE`:
-- Esta e' a UNICA tabela do projeto cujo dado nao vem do pipeline -- vem de
-- gente. Todas as outras sao reconstruiveis a partir do codigo: apagar e
-- redeployar devolve o mesmo conteudo. Esta, nao. Um `CREATE OR REPLACE`
-- num redeploy apagaria em silencio tudo o que o time respondeu.
--
-- E' tambem por isso que ela nao tem teste de contagem: zero linha aqui e'
-- o estado CORRETO no comeco.
-- =====================================================================

CREATE TABLE IF NOT EXISTS lakehouse_rotaperfume.gold.retorno_ligacao (
  cliente_id      INT       COMMENT 'Cliente que foi contatado. Casa com cliente_id de gold.fila_semanal e gold.dim_cliente.',
  vendedor        STRING    COMMENT 'Nome do vendedor que fez a ligacao, como aparece em gold.fila_semanal.',
  status          STRING    COMMENT 'Resultado da ligacao. Valores possiveis: vendeu, vai_pensar, sem_interesse, nao_atendeu. Só `vendeu` conta como conversao.',
  comentario      STRING    COMMENT 'Texto livre do vendedor sobre a conversa. Pode ser nulo.',
  registrado_em   TIMESTAMP COMMENT 'Quando o retorno foi registrado. Um cliente pode ter varios retornos: para o estado atual, use o mais recente por esta coluna.',
  registrado_por  STRING    COMMENT 'E-mail de quem estava logado ao registrar. Serve para auditoria, nao para cobrar pessoa.',
  _referencia     DATE      COMMENT 'Semana da fila a que este retorno se refere. Casa com _referencia de gold.fila_semanal.'
)
COMMENT 'Retorno das ligacoes da fila semanal: o que aconteceu depois do contato. E a UNICA tabela do projeto alimentada por pessoas e nao pelo pipeline, por isso nunca e recriada num deploy. Comeca vazia -- zero linhas significa que ninguem registrou retorno ainda, e nao que ninguem vendeu.';

-- Uma consulta de estado, para conferir sem abrir a tabela.
SELECT
  'retorno_ligacao' AS tabela,
  COUNT(*)          AS registros,
  COUNT(DISTINCT cliente_id) AS clientes_com_retorno,
  SUM(CASE WHEN status = 'vendeu' THEN 1 ELSE 0 END) AS viraram_pedido,
  CASE WHEN COUNT(*) = 0
       THEN 'vazia -- ninguem registrou retorno ainda, e este e o estado correto no inicio'
       ELSE 'com registros' END AS situacao
FROM lakehouse_rotaperfume.gold.retorno_ligacao;
