# Lakehouse RotaPerfume

Lakehouse completo no Databricks para uma distribuidora de perfumes fictícia, construído como
Declarative Automation Bundle (DAB) — do arquivo CSV até o dashboard, tudo versionado e
reproduzível com um `deploy`.

O projeto nasceu de um mini-curso de engenharia de dados. O material didático não está aqui:
este repositório é a **implementação**, com as decisões de arquitetura documentadas em
[`docs/decisoes.md`](docs/decisoes.md).

---

## O que existe aqui

Um único catálogo Unity Catalog em arquitetura medalhão, e um job de 10 tarefas que o preenche
inteiro:

```
raw_conferencia ──> bronze_ingestao ──> silver_clientes ──┐
                                        silver_pedidos     │
                                        silver_itens_...   ├─> gold_dimensoes
                                        silver_crm_fin. ──┘      └─> gold_fato_vendas
                                        (4 em paralelo)               └─> gold_marts
                                                                          └─> testes
```

| Camada | Conteúdo |
|---|---|
| `bronze.raw` (Volume) | os 10 CSVs originais, byte por byte |
| `bronze` | 10 tabelas Delta — **tudo `STRING`**, sujeira preservada de propósito |
| `silver` | 10 tabelas limpas e tipadas, com 5 `CHECK` constraints do Delta |
| `gold` | 4 dimensões conformadas, `fato_vendas` (191.080 linhas), 3 marts, 9 testes |
| dashboard | AI/BI declarado em JSON, versionado, sobe junto no `deploy` |

**Raw é arquivo; bronze é tabela.** A separação é deliberada: quando alguém pergunta "esse
número veio de onde?", a linhagem termina num arquivo, não numa opinião.

### O número que amarra tudo

**R$ 102.303.828,05.** É a soma dos pedidos não cancelados na bronze, e ela precisa atravessar
todas as camadas sem mudar — `silver.pedidos`, `gold.fato_vendas` e os dois marts de vendas
somam exatamente isso. Dois dos nove testes existem só para garantir essa invariante, e é o que
a palavra "conformado" significa na prática.

> Uma boa limpeza não muda o faturamento. Se mudou, alguma linha foi descartada sem querer.

---

## Rodando

Pré-requisitos: [Databricks CLI](https://docs.databricks.com/dev-tools/cli/install), um perfil
autenticado (`databricks auth login`), [uv](https://docs.astral.sh/uv/) e Git Bash no Windows.

O bundle não fixa host nem usuário: o workspace vem do seu perfil, então **sempre passe
`--profile`**.

```bash
cd rotaperfume
uv sync --dev

# 1. o catalogo, por SQL (ver docs/decisoes.md para o porque)
bash scripts/criar-catalogo.sh <perfil>

# 2. schemas, volume, job e dashboard
databricks bundle deploy --target dev --profile <perfil>

# 3. os CSVs sobem para o Volume
bash scripts/subir-raw.sh <perfil>

# 4. o pipeline inteiro
databricks bundle run rotaperfume_pipeline --target dev --profile <perfil>
```

A ordem importa duas vezes: o catálogo precisa existir antes do deploy criar os schemas, e o
Volume precisa existir antes de receber arquivo.

Descubra o seu SQL Warehouse e ajuste a variável:

```bash
databricks experimental aitools tools get-default-warehouse --profile <perfil>
databricks bundle deploy --target dev --profile <perfil> --var warehouse_id=<id>
```

### Conferindo

```sql
-- os 10 arquivos chegaram e a bronze bate com eles
SELECT COUNT(*) AS arquivos, SUM(linhas) AS linhas
FROM lakehouse_rotaperfume.bronze._raw_arquivos;   -- 10 · 313.551

-- a limpeza nao mudou o faturamento
SELECT (SELECT ROUND(SUM(valor_liquido),2) FROM lakehouse_rotaperfume.silver.pedidos) AS silver,
       (SELECT ROUND(SUM(receita),2)       FROM lakehouse_rotaperfume.gold.fato_vendas) AS gold;
-- 102303828.05 nas duas
```

---

## Estrutura

```
rotaperfume/            o bundle
  databricks.yml        targets dev/prod, variaveis
  resources/            catalogo, job, dashboard (JSON + recurso)
  scripts/              criar-catalogo.sh, subir-raw.sh
  src/raw/              conferencia de chegada (notebook serverless)
  src/bronze/           ingestao: uma funcao, uma lista de 10
  src/silver/           4 arquivos SQL por assunto
  src/gold/             dimensoes, fato, marts, testes
erp/ crm/               os 10 CSVs de origem (313.551 linhas)
docs/decisoes.md        por que cada decisao foi tomada
CLAUDE.md               contexto de arquitetura para agentes de IA
```

Os dados são **sintéticos**: uma distribuidora fictícia, gerada com semente fixa. A sujeira
neles (CNPJ em três formatos, datas em dois padrões, cadastros duplicados) é intencional — é o
material sobre o qual a camada silver trabalha.

---

## Ambiente

Construído no **Databricks Free Edition**, o que impõe restrições reais e visíveis no código:
tudo é serverless (nenhum cluster é declarado em lugar nenhum) e o catálogo não pode ser criado
pela API do Unity Catalog. As duas coisas estão explicadas em
[`docs/decisoes.md`](docs/decisoes.md).

## Crédito

A modelagem do caso e o dataset vêm de um mini-curso de engenharia de dados no Databricks. A
implementação, as decisões documentadas e as correções deste repositório são minhas.
