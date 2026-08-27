# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Databricks lakehouse build for a fictional perfume distributor ("rotaperfume"), used as a
hands-on course project. Three top-level areas:

- `rotaperfume/` — the Declarative Automation Bundle (DAB). All code and infrastructure lives here.
- `crm/`, `erp/` — the 10 source CSVs (~14 MB, 313,551 data rows) that get uploaded to a Unity
  Catalog Volume. These are the *inputs*, not bundle assets.
- `.llm/` — the delivery specs (`prompt_01.md`, …). Each prompt is one incremental delivery that
  extends the **same** bundle. Read the relevant prompt before implementing: it carries the target
  state, the expected row counts, and the deliberate traps.

Deliveries 1–5 are **done and deployed**: raw → Volume + arrival check, bronze (10 Delta
tables), silver (10 cleaned tables + 5 Delta constraints), gold (4 dimensions, `fato_vendas`,
3 marts, 9 tests), and the dashboard as code. Delivery 6 (Genie) is the last one.

## Commands

All commands run from `rotaperfume/`. The only profile is `DEFAULT` — always pass it explicitly.

```bash
uv sync --dev                                # install deps (uv, not pip)
uv run pytest                                # run tests
uv run pytest tests/test_x.py::test_name     # single test
uv run ruff check . && uv run ruff format .  # lint / format (line-length 120)

bash scripts/criar-catalogo.sh DEFAULT       # catalog (SQL — see below)
databricks bundle validate --strict --target dev --profile DEFAULT
databricks bundle deploy   --target dev --profile DEFAULT
bash scripts/subir-raw.sh  DEFAULT           # CSVs -> Volume
databricks bundle run rotaperfume_pipeline --target dev --profile DEFAULT
```

Order matters twice: the catalog must exist before the deploy creates schemas, and the Volume must
exist before files are uploaded into it.

Ad-hoc SQL (there is no `databricks sql execute`):
`databricks experimental aitools tools query "<SQL>" --profile DEFAULT`

Tests are **not** offline: `tests/conftest.py` initializes Databricks Connect and eagerly builds a
`SparkSession` against the workspace, falling back to `DATABRICKS_SERVERLESS_COMPUTE_ID=auto`. The
`spark` and `load_fixture` fixtures (JSON/CSV out of `fixtures/`) are the intended way in.

## Architecture

Medallion layout in a single Unity Catalog catalog. Everything below the catalog is a bundle
resource in `resources/catalogo.yml`, so a `bundle deploy` recreates it identically:

```
lakehouse_rotaperfume
├── bronze   ── volume `raw` (MANAGED)  ← the 10 CSVs, byte-for-byte
│              ├── _raw_arquivos        ← arrival-check control table
│              └── 10 Delta tables      ← everything STRING, dirt intact
├── silver   ── 10 tabelas limpas e tipadas, com CHECK constraints
└── gold     ── 4 dimensões + fato_vendas (191.080) + 3 marts
```

`raw` (files in a Volume) is deliberately distinct from `bronze` (tables), so lineage terminates in
an actual file rather than an opinion.

`resources/pipeline.job.yml` defines `rotaperfume_pipeline`, which accumulates tasks per
delivery — its header comment carries the shape. Today: `raw_conferencia` → `bronze_ingestao` →
the four `silver_*` tasks **in parallel** → `gold_dimensoes` → `gold_fato_vendas` →
`gold_marts` → `testes`. Tasks chain with `depends_on`, so a failed check stops everything
downstream — and `testes` is last on purpose: if it fails, the dashboard keeps yesterday's data
instead of today's wrong data.

- `raw_conferencia` verifies all 10 expected files exist and are non-empty, writes
  `bronze._raw_arquivos (sistema, arquivo, bytes, linhas, conferido_em)`, and **raises** on any
  missing file so downstream tasks never run on partial data.
- `bronze_ingestao` loads each CSV into `bronze.<tabela>` with one function over one list, then
  **raises** if any table's count diverges from `_raw_arquivos`. Note `_raw_arquivos.linhas`
  already excludes the header — do not subtract it again.

## Environment constraints

- **Databricks Free Edition — serverless only.** Never declare a cluster. A job task with no
  `new_cluster` / `job_cluster_key` / `existing_cluster_id` *is* the serverless configuration.
- **The catalog cannot be created by the bundle.** Default Storage is on, so the UC API rejects
  `CREATE CATALOG` without a managed location (`Metastore storage root URL does not exist`,
  400 INVALID_STATE). It is created via SQL in `scripts/criar-catalogo.sh`; schemas and volumes
  *do* work as bundle resources.
- **Never add `mode: development`.** It prefixes resource names with `[dev <user>]` including UC
  schemas (`dev_tadeu_bronze`), breaking every hardcoded SQL path. The dev target instead uses
  `presets: { trigger_pause_status: PAUSED }` to pause schedules without renaming anything.
- **`databricks fs cp` needs the `dbfs:` scheme** on the destination even for a UC Volume:
  `dbfs:/Volumes/<catalog>/bronze/raw/...`.
- dev and prod point at the **same** catalog (single workspace). Deploying prod overwrites the dev
  job; only dev is exercised in class.
- Python notebooks start with `# Databricks notebook source`; cells split on `# COMMAND ----------`.

## Workspace facts

The specs in `.llm/` were written against a different workspace. What is actually true here:

| | |
|---|---|
| Profile / host | comes from `~/.databrickscfg` — `databricks.yml` declares no host, so always pass `--profile <name>` |
| SQL Warehouse | set via the `warehouse_id` bundle variable — the specs name a different one, from another workspace |
| Data location | `erp/`, `crm/` at repo root (specs say `dados/erp`, `dados/crm`) |
| Bundle location | `rotaperfume/` at repo root (specs say `aulas/aula-02-.../rotaperfume/`) |

`material/gerar_dataset.py` and `prd/CLAUDE.md`, referenced by the specs, do not exist here.

## Source data

10 files, each name matching its header's primary key. Totals are load-bearing — the arrival check
and the course's verification queries assert them:

| System | Files | Rows |
|---|---|---|
| `erp/` | produtos (292), pedidos (28.729), itens_pedido (197.724), pagamentos (27.772), estoque (8.400) | 262.917 |
| `crm/` | clientes (3.040), vendedores (42), carteira (3.637), oportunidades (5.979), visitas (37.936) | 50.634 |
| **Total** | **10** | **313.551** |

## The bronze contract

Deliveries 3–6 must not "fix" the bronze. Its rules, and why:

- **Read with `spark.read.csv(...).option("inferSchema", False)`** — every business column is
  `STRING` on purpose. Letting Spark infer turns CNPJ into a number and silently drops the leading
  zero on 309 clients, and turns `15/10/2025` into null. Conversion is the silver's job.
- **Plain CSV reader, never `read_files`** — `read_files`/Auto Loader invents a `_rescued_data`
  column, and `rescuedDataColumn => ''` does not disable it (it creates an empty-named column that
  breaks `CREATE TABLE`).
- **No `multiLine`** — verified safe: none of the 10 files has quotes or embedded newlines, so
  physical lines equal CSV records in all 10. Turning it on changes counts without warning.
- **Exactly two added columns**: `_ingerido_em` (timestamp) and `_arquivo_origem`
  (`_metadata.file_path` — `input_file_name()` does not work on serverless/Spark Connect).
- **The dirt is the point.** It is the proof a bad number came from the source and not from our
  cleanup. Measured and intact in `bronze.clientes`: 3.040 rows / 1.111 punctuated CNPJs / 223 with
  surrounding spaces / 309 with a leading zero / 347 dates in `dd/MM/yyyy` / 40 duplicate CNPJs
  (3.000 unique — the duplicates share a CNPJ, **not** a `cliente_id`, so `DISTINCT` will not
  remove them).

## The canonical number

**R$ 102.303.828,05.** It is the sum of non-cancelled order value in the bronze, and it must
survive every layer unchanged — `silver.pedidos.valor_liquido`, `gold.fato_vendas.receita`,
`mart_vendas_por_vendedor` and `mart_produto_performance` all sum to it. That invariant is what
"conformado" means here, and test 1 and test 8 in `src/gold/08-testes.sql` enforce it. If a
change moves this number, a row was dropped by accident — fix the transformation, never the test.

Other measured anchors: `fato_vendas` has **191.080** rows (197.724 items minus the 6.644 items
of the 957 cancelled orders, ≈6,9 items per order); gross sold is **103.568.586,35** and
returns are **−1.264.758,30**; margin is **41.125.619,86 (40,2%)**.

## Silver and gold decisions (deliveries 3–6 must not undo these)

- **`try_to_date` everywhere.** ANSI mode is on: `to_date` on a malformed date **aborts the
  query** with `CAST_INVALID_INPUT` — it does not return null. Every date is
  `coalesce(try_to_date(x), try_to_date(x, 'dd/MM/yyyy'))`.
- **Returns are flagged, never dropped.** Negative `quantidade` is a return (2.327 items).
  Dropping them inflates revenue by R$ 1,26 mi; keeping them unflagged pollutes every sum.
  `devolucao` preserves both numbers.
- **Orphans are exposed, never fixed.** 441 carteiras stay open under a terminated seller;
  `orfao_vendedor_desligado` hands the problem to the manager instead of hiding it.
- **Dedup is deterministic.** All 40 duplicate CNPJ pairs share the *same* `data_cadastro`, so
  `ORDER BY data_cadastro` alone is non-deterministic. The tie-break is `cliente_id ASC`, which
  keeps the original registration. Discarded ids live on in `cliente_ids_duplicados`.
- **The constraint that looks wrong is right.** `valor_liquido >= 0` fails on 135 orders that
  contain a returned item — legitimate business. The real rule is
  `NOT cancelado OR valor_liquido = 0`.
- **Opportunity stages are `Fechado ganho` / `Fechado perdido`** — not `Ganha`/`Perdida`. A
  `CASE` written from memory returns zero on every row, silently.
- **Marts read only `fato_vendas`.** Never a second fact per department: they diverge within
  months and nobody knows which is right.

## SQL tasks

`src/silver/*.sql` and `src/gold/*.sql` run as `sql_task` on the warehouse, not on serverless
notebooks. A `.sql` file may hold several statements separated by `;` — that is what lets one
file carry `CREATE OR REPLACE TABLE` + `COMMENT ON` + `ALTER TABLE ADD CONSTRAINT` per subject.
Each constraint is preceded by `DROP CONSTRAINT IF EXISTS` so re-runs are idempotent. Avoid `;`
inside string literals; it survives the server parser but breaks naive local splitting.

## Dashboard as code

`resources/dashboard-comercial.lvdash.json` + `resources/dashboard.dashboard.yml`. Rules that
break it silently: queries use **bare table names** (`FROM fato_vendas`) because catalog and
schema come from `dataset_catalog`/`dataset_schema`; `query.fields[].name` must equal
`encodings.*.fieldName`; counter and table are `version: 2`, bar and line `version: 3`, filters
`version: 2`; every page needs `layoutVersion: GRID_V1`; counters take no per-widget color.
The main dataset is at **item grain on purpose** — pre-aggregating destroys `pedido_id` and
silently breaks `COUNT(DISTINCT pedido_id)`, so the order count and ticket average would be
wrong.

**Never name a `dataset.columns` measure after a column of the same dataset.** SQL identifiers
are case-insensitive, so a measure `Receita` whose expression is ``SUM(`receita`)`` is read as
referencing itself and every widget using it dies with
`BAD_REQUEST: Circular reference detected in calculated field: receita`. Name it
`Receita Total`. The shipped version avoids `MEASURE()` entirely and uses inline aggregations
(``SUM(`receita`)`` named `sum(receita)`); inline expressions cannot divide, so the two ratio
metrics (ticket average, margin %) come from small pre-aggregated datasets — and therefore do
not participate in cross-filtering.

## Conventions

- Docs, prompts, table names, column names, and code comments are in **Portuguese**. Keep it that
  way — the verification SQL in `.llm/` depends on those exact identifiers.
- Shell scripts are `.sh`, run via Git Bash on this Windows machine. They take the profile as `$1`
  with no default, so the profile is never implicit.
- Every schema, volume, and table carries a `COMMENT` explaining its role in one sentence.
- `rotaperfume/AGENTS.md` (imported by `rotaperfume/CLAUDE.md`) asks agents to load the
  `databricks-core` skill before Databricks work, plus the matching product skill
  (`databricks-dabs`, `databricks-jobs`, `databricks-unity-catalog`, …).
