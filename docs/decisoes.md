# Decisões de arquitetura

Este documento é o que separa "segui um tutorial" de "entendi o problema". Cada item aqui é uma
decisão que precisou ser tomada, com o motivo e — onde couber — o número que a justifica.

Os cinco primeiros são armadilhas que só apareceram **medindo**: nenhuma delas dá erro. Todas
produzem um número errado com cara de número certo, que é a categoria de bug mais cara que
existe em dados.

---

## 1. A deduplicação era não-determinística, e ninguém veria

**O problema.** 3.040 cadastros de clientes contêm 3.000 CNPJs distintos: 40 empresas estão
cadastradas duas vezes. `DISTINCT` não resolve, porque o `cliente_id` é diferente em cada
cadastro — para o banco, são dois clientes.

A regra natural é "mantenha o cadastro mais antigo":

```sql
row_number() OVER (PARTITION BY cnpj ORDER BY data_cadastro)
```

**O que a medição mostrou.** Os 40 pares têm `data_cadastro` **idêntica**. Nenhum nulo, nenhuma
diferença — empate em 100% dos casos.

```sql
-- 40 CNPJs duplicados, todos com uma unica data distinta entre os dois cadastros
SELECT COUNT(*) FROM (
  SELECT cnpj_limpo FROM normalizado
  GROUP BY cnpj_limpo HAVING COUNT(*) > 1 AND COUNT(DISTINCT data_cadastro) < COUNT(*)
);  -- 40
```

Com empate total, `ORDER BY data_cadastro` é uma ordenação **arbitrária**: cada execução pode
manter um `cliente_id` diferente, e a coluna `cliente_ids_duplicados` muda junto. O pipeline
roda verde todo dia e devolve resultado diferente.

**A decisão.** Desempatar por `cliente_id`, que é estável e — verificado — sempre o menor id é o
cadastro original (os duplicados são todos ids altos, anexados depois):

```sql
row_number() OVER (PARTITION BY cnpj ORDER BY data_cadastro, cliente_id)
```

O id descartado não some: fica em `cliente_ids_duplicados`, porque pedidos antigos ainda
apontam para ele.

---

## 2. A constraint intuitiva estava errada

A regra que qualquer um escreveria para o valor de um pedido:

```sql
ALTER TABLE silver.pedidos ADD CONSTRAINT valor_positivo CHECK (valor_liquido >= 0);
```

Ela **falha**, em 135 pedidos. E os 135 não são sujeira: são pedidos que contêm item devolvido,
cujo saldo ficou negativo. Negócio legítimo.

A regra que realmente se quer garantir é outra — pedido cancelado tem que ter valor zero:

```sql
ADD CONSTRAINT pedido_cancelado_zerado CHECK (NOT cancelado OR valor_liquido = 0)
```

**O ponto geral:** uma constraint que falha fez o trabalho dela. Ela transformou uma suposição
em pergunta antes de a suposição virar número no dashboard. O erro seria relaxar a constraint em
vez de investigar por que ela disparou.

---

## 3. Devolução: três caminhos, três faturamentos diferentes

Quantidade negativa em `itens_pedido` não é erro, é devolução — 2.327 itens. Existem três
saídas, e cada uma entrega um número diferente ao diretor:

| Caminho | Faturamento | Problema |
|---|---|---|
| Descartar as linhas negativas | R$ 103.568.586,35 | **infla** a receita em R$ 1,26 mi |
| Manter, sem sinalizar | R$ 102.303.828,05 | toda soma da empresa fica poluída, sem como separar |
| **Manter, com flag** | R$ 102.303.828,05 | nenhum — os dois números continuam obteníveis |

A coluna `devolucao` (boolean) preserva ambos. Quem quer o bruto pede explicitamente:

```sql
SELECT SUM(receita) FILTER (WHERE NOT devolucao) FROM gold.fato_vendas;
```

O mesmo princípio vale para as 441 carteiras de vendedor desligado: a silver **expõe** o
problema em `orfao_vendedor_desligado` em vez de fechá-las. Consertar o dado apagaria a
evidência de um problema de processo que alguém precisa resolver.

---

## 4. Pré-agregar o dashboard quebraria o ticket médio em silêncio

Ao montar o dashboard, o caminho óbvio é reduzir o dataset: agregar `fato_vendas` por
`ano, mes, canal, segmento, cidade, marca, categoria` derruba 191.080 linhas para 127.494.

Mas `pedido_id` não sobrevive à agregação — e duas métricas dependem dele:

```
pedidos      = COUNT(DISTINCT pedido_id)
ticket medio = SUM(receita) / COUNT(DISTINCT pedido_id)
```

Sem `pedido_id` no grão, os dois viram contagem de linhas agregadas. O cartão continua
mostrando um número, com formatação bonita, e ele está errado.

**A decisão:** o dataset principal fica no **grão de item**. O ganho de performance da
pré-agregação não paga uma métrica errada num painel de diretoria.

---

## 5. Referência circular numa métrica de dashboard

Declarando métricas reutilizáveis no dataset do AI/BI:

```json
{"displayName": "Receita", "expression": "SUM(`receita`)"}
```

O dataset já tem uma coluna `receita`. Como identificador SQL é case-insensitive, o motor lê a
métrica `Receita` como referência a si mesma:

```
BAD_REQUEST: Circular reference detected in calculated field: receita
```

Dez dos catorze widgets morrem juntos — os que usam métrica. Tabela e filtros continuam de pé,
e é esse contraste que localiza a causa.

**A regra:** nome de métrica nunca pode colidir com nome de coluna do mesmo dataset.
`Receita Total`, não `Receita`.

---

## 6. A bronze não conserta nada — de propósito

Toda coluna de negócio na bronze é `STRING`, com `inferSchema` desligado. Não é preguiça:

```sql
-- com inferencia de tipo ligada, o CNPJ vira numero
SELECT cnpj FROM ... -- '01234567000199' vira 1234567000199
```

São **309 clientes** cujo documento fica errado para sempre, sem erro nenhum. E `15/10/2025`
vira nulo. A sujeira medida e preservada na bronze:

| | |
|---|---|
| CNPJ pontuado | 1.111 |
| CNPJ com espaço em volta | 223 |
| CNPJ com zero à esquerda | 309 |
| Datas em `dd/MM/yyyy` | 347 (em clientes) |
| CNPJs duplicados | 40 |

A sujeira é a **prova** de que um número ruim veio da origem e não da nossa limpeza. Converter é
trabalho da silver, feito uma vez, sabendo o que se faz.

Duas escolhas técnicas seguem daí:

- **Leitor CSV comum, nunca `read_files`.** O Auto Loader inventa uma coluna `_rescued_data`, e
  `rescuedDataColumn => ''` não desliga — cria uma coluna de nome vazio que quebra o
  `CREATE TABLE`.
- **`_metadata.file_path`, não `input_file_name()`.** A segunda não funciona em serverless
  (Spark Connect).

---

## 7. ANSI mode: `to_date` aborta, não devolve nulo

No Databricks SQL, com ANSI mode ligado, data malformada **interrompe a query**:

```sql
SELECT date_trunc('month', to_date(data_pedido)) FROM bronze.pedidos;
-- [CAST_INVALID_INPUT] The value '15/10/2025' cannot be cast to "DATE"
```

Esse erro é o bom: aparece na cara. O ruim é o banco que devolve `NULL` calado e o mês some do
relatório três meses depois.

Toda conversão de data no projeto usa o par:

```sql
coalesce(try_to_date(x), try_to_date(x, 'dd/MM/yyyy'))
```

Isso derruba pipeline em produção no dia em que a origem manda o outro formato — e é o tipo de
coisa que passa meses funcionando antes de quebrar.

---

## 8. `mode: development` renomeia schemas do Unity Catalog

O padrão do template `default-python` traz `mode: development` no target dev. Ele prefixa o nome
dos recursos com `[dev <usuario>]` — **incluindo os schemas do UC**, que virariam
`dev_fulano_bronze` e quebrariam todo o SQL que referencia `bronze`, `silver`, `gold`.

O único efeito desejável dele é pausar o agendamento, e isso se pede diretamente:

```yaml
presets:
  trigger_pause_status: PAUSED
```

---

## 9. O catálogo não pode nascer do bundle

No Free Edition o Default Storage está ligado, e nessa configuração a API do Unity Catalog
recusa criar catálogo — exige um MANAGED LOCATION que a conta não tem:

```
Metastore storage root URL does not exist.
Default Storage is enabled in your account. (400 INVALID_STATE)
```

O comando SQL funciona. Por isso o catálogo nasce em `scripts/criar-catalogo.sh` e todo o resto
— schemas, volume, job, dashboard — é recurso do bundle. É a fronteira entre "o que o Terraform
do DAB consegue" e "o que a plataforma permite", e ela precisa estar documentada onde alguém vá
tropeçar.

---

## 10. Detalhes que custam uma execução cada

- **`_raw_arquivos.linhas` já exclui o header.** Foi contado com `header=True`. Subtrair de novo
  na conferência da bronze dá −1 em cada uma das dez tabelas.
- **`databricks fs cp` exige o esquema `dbfs:`** no destino, mesmo o destino sendo um Volume do
  UC: `dbfs:/Volumes/<catalogo>/bronze/raw/...`.
- **Um arquivo `.sql` de `sql_task` aceita vários statements** separados por `;` — é o que
  permite `CREATE OR REPLACE TABLE` + `COMMENT ON` + `ALTER TABLE ADD CONSTRAINT` no mesmo
  arquivo, por assunto. Evite `;` dentro de literais de texto: o servidor entende, mas qualquer
  ferramenta que divida o arquivo localmente não.
- **`multiLine` fica desligado.** Verificado nos 10 arquivos: linhas físicas == registros CSV.
  Ligar muda a contagem sem avisar.
- **Teste que não quebra o job não é teste, é relatório.** Os 9 testes usam `raise_error()`
  dentro de `CASE WHEN`, e a tarefa é a última do DAG. Se um falha, o dashboard fica com o dado
  de ontem — que é infinitamente melhor do que o dado errado de hoje.
