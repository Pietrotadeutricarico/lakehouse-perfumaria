-- @param vendedor STRING
-- Os 200 contatos da semana. 'Todos' nao filtra -- o parametro sempre vem
-- preenchido, entao a comparacao com 'Todos' e' o que libera a lista inteira.
--
-- LEFT JOIN com o retorno MAIS RECENTE de cada cliente: um cliente pode ter
-- varios retornos, e o que importa na tela e' o estado atual dele.
WITH ultimo_retorno AS (
  SELECT cliente_id, status, comentario, registrado_em, registrado_por
  FROM lakehouse_rotaperfume.gold.retorno_ligacao
  QUALIFY ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY registrado_em DESC) = 1
)
SELECT
  f.ordem,
  f.cliente_id,
  f.razao_social,
  f.cidade,
  f.uf,
  f.vendedor,
  f.score,
  f.faixa,
  f.ticket_medio,
  f.motivo,
  f.sugestao,
  r.status        AS retorno_status,
  r.comentario    AS retorno_comentario,
  r.registrado_em AS retorno_em
FROM lakehouse_rotaperfume.gold.fila_semanal f
LEFT JOIN ultimo_retorno r ON r.cliente_id = f.cliente_id
WHERE :vendedor = 'Todos' OR f.vendedor = :vendedor
ORDER BY f.score DESC
