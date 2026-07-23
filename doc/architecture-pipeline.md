# Architectural Specification: PowerBuilder-to-JSON AST Compiler Front-End

## Subtitle: Static Analysis & LLM-Driven Code Querying via DuckDB SQL

---

## 1. Executive Summary & Core Philosophy

This document defines the architectural strategy, data design, and downstream workflow for
compiling a legacy PowerBuilder codebase (~300KLOC across 1,700 source files) into a
unified, rich Abstract Syntax Tree (AST) compiled and analysed by a Haskell
pipeline that writes results directly into a **DuckDB relational database**
enabling SQL-based cross-file analysis.

### The Core Problem

Legacy PowerBuilder codebases (`.srd`, `.sru`, `.srw`, `.srm`, `.sjp`) are inherently
hostile to modern static analysis tools and Large Language Models (LLMs). They are
heavily polluted with visual layout metadata (coordinates, font metrics, colour bytes),
rely on complex implicit object-oriented inheritance loops, and embed a unique mix of
procedural PowerScript, proprietary `PBSELECT` metadata, and native PL/SQL blocks.
Feeding raw source files into an LLM causes prompt context exhaustion, high token costs,
and catastrophic model hallucinations due to the language training gap.

### The Solution: Structural Separation + Relational Query

We bypass text-based reading by compiling the codebase with a **Megaparsec**
front-end and writing canonical fact tables directly into **DuckDB**. This enables:

- **The LLM writes SQL, not code searches:** It converts natural language questions into
  deterministic SQL queries against `pb.duckdb`, executed locally in milliseconds.
- **The LLM reads pseudo-PBScript, not JSON:** The Explore UI (backed by `body_json`/
  `instr_graph_json`) renders any function or event body back to readable PowerScript,
  reducing context token cost and hallucination risk.
- **Diagrams communicate structure:** the `/api/diagram*` endpoints (`cli/api/src/pb/api/
  routes/diagrams.py`) generate GraphViz SVGs for inheritance hierarchies, call graphs,
  DW-table dependencies, complexity heatmaps, CFGs, and wiring diagrams — synchronously
  for small graphs, or via an async job/poll path (`/api/diagram-jobs/{job_id}`) for
  slower renders.

---

## 2. LLM + DuckDB Integration Workflow (Agentic Tool-Use)

To execute complex system-wide audits — discovering every form validation rule or tracing
database lineage — the system runs a multi-stage agentic loop.

```
┌──────────────────┐   1. Natural Language Question    ┌───────────┐
│                  ├─────────────────────────────────>│           │
│                  │                                   │    LLM    │
│                  │   2. Generates SQL Query          │           │
│                  │<─────────────────────────────────┤           │
│       User       │                                   └───────────┘
│   (or Agentic    │
│    Pipeline)     │   3. Executes SQL locally
│                  ├──────────────────────┐
│                  │                      ▼
│                  │             ┌─────────────────┐
│                  │             │   pb.duckdb     │
│                  │             │  fact tables    │
│                  │             └────────┬────────┘
│                  │                      │ 4. Returns focused
│                  │                      │    tabular result
│                  │<─────────────────────┘
└──────────────────┘   5. (Optional) LLM call:
                           Explore UI / body_json shows code body;
                           LLM summarises into English
```

### Why DuckDB SQL (not jq or Datalog)

| Concern | jq | Datalog (Soufflé) | DuckDB SQL |
|---|---|---|---|
| LLM query accuracy | fragile on novel shapes | almost no training data | excellent |
| Cross-file joins | impossible | natural | natural |
| Recursive queries | impossible | native | recursive CTEs |
| Graph metrics | impossible | native | via Python NetworkX |
| Setup | zero | compile step | zero (embedded) |

**Soufflé/Datalog** is the theoretically correct model for fixed-point program analysis
(call-graph reachability, points-to analysis). It is noted here as a deferred second-tier
tool: if DuckDB recursive CTEs prove insufficient for a specific analysis, pre-compute the
result in Soufflé and load it back into DuckDB as an additional table. No evidence of
this need exists yet for the stated use cases.

### Complete Operational Pipeline

1. **Question:** A developer asks: *"What field validations are enforced when updating
   an invoice, and what database tables do they hit?"*
2. **Query Generation:** The LLM receives the `pb.duckdb` schema (§5) and generates SQL.
3. **Local Execution:** DuckDB runs the query against indexed fact tables — milliseconds,
   not minutes.
4. **Render (optional):** The UI's Explore feature renders any procedure body from
   `procedures.instr_graph_json`/`wiring_json` back to readable pseudo-PBScript
   client-side (`ui/packages/interpreter/`), served through the FastAPI/SPA layer.
5. **Synthesis:** The LLM translates the focused result into a markdown analysis.

### Concrete Simulation: Analysis of Form Validations

#### Input Scenario

A DataWindow control inside `w_invoice_entry.srw` tracks `d_invoice_detail.srd`.
Validations are split across DW field expressions, the `ItemChanged` event, and an
inline validation function.

#### Step 1: LLM-Generated SQL Query

```sql
-- Find all validation-related procedures and DW expressions for invoice forms
WITH invoice_objects AS (
    SELECT name, ancestor FROM objects
    WHERE name LIKE '%invoice%'
),
val_procs AS (
    SELECT p.file, p.object, p.proc_type, p.name, p.start_line, p.end_line
    FROM procedures p
    JOIN invoice_objects o ON p.object = o.name
    WHERE p.name IN ('itemchanged', 'pbm_dwnitemchange')
       OR lower(p.name) LIKE '%validate%'
       OR lower(p.name) LIKE '%check%'
       OR lower(p.name) LIKE '%verify%'
),
val_dw AS (
    SELECT dc.file, dc.dw_name, dc.control_name, dc.expression
    FROM dw_controls dc
    JOIN invoice_objects o ON dc.file LIKE '%' || lower(o.name) || '%'
    WHERE dc.expression IS NOT NULL
),
referenced_tables AS (
    SELECT dt.file, dt.table_name
    FROM dw_retrieve_tables dt
    WHERE dt.file LIKE '%invoice%'
)
SELECT
    p.file AS source_file,
    p.object AS context_object,
    o.ancestor AS ancestor_class,
    p.proc_type AS logic_type,
    p.name AS identifier,
    p.start_line,
    p.end_line,
    (SELECT json_group_array(rt.table_name)
     FROM referenced_tables rt WHERE rt.file = p.file) AS referenced_tables
FROM val_procs p
JOIN invoice_objects o ON p.object = o.name

UNION ALL

SELECT
    dc.file, dc.dw_name, 'w_invoice_entry', 'dw_expression',
    dc.control_name, NULL, NULL,
    '[]'
FROM val_dw dc;
```

#### Step 2: Focused Result (fed back to LLM)

```
source_file                  | context_object    | logic_type    | identifier      | start_line | referenced_tables
d_invoice_detail.srd         | d_invoice_detail  | dw_expression | invoice_amt     | -          | []
w_invoice_entry.srw          | w_invoice_entry   | event         | itemchanged     | 147        | ["customer"]
w_invoice_entry.srw          | w_invoice_entry   | function      | of_check_amount | 203        | []
```

#### Step 3: Optional — render the event body

There is no CLI render flag; the Explore feature in the UI renders a
procedure's body (from `procedures.instr_graph_json`/`wiring_json`, looked
up by object + procedure name) back to readable pseudo-PowerScript:

```powerscript
// itemchanged  [event]
// object: w_invoice_entry  •  ancestor: w_master_entry
// file:   src/w_invoice_entry.srw  •  lines: 147–178

if dwo.name = 'customer_id' then
  if :customer.status from db where id = :data is 'SUSPENDED' then
    reject
  end if
end if
```

#### Step 4: Final Semantic Output

The LLM processes the SQL result and pseudo-PBScript body and outputs:

> ### Invoice Form Validation Summary
>
> - **DataWindow Bounds:** `d_invoice_detail.srd` enforces `invoice_amt > 0.00` at the
>   data layer via a column expression.
> - **State-Based Lifecycle:** The `itemchanged` event in `w_invoice_entry.srw` (lines
>   147–178) checks `customer.status = 'SUSPENDED'` and rejects the update.
> - **DB Tables Hit:** `customer` (via the `itemchanged` host variable query).

---

## 3. JSON Serialisation & Schema Guidance

### Crucial Data Anchors (on every callable block node)

- **`.meta.file`**: Repository-relative path to the `.sr*` file.
- **`.meta.object`**: Name of the owning `global type` declaration.
- **`.meta.ancestor`**: Declared ancestor class from the file's own `TypeDecl`. Not
  cross-file resolved — join across the `objects` manifest to walk the full chain.
- **`.meta.startLine`** / **`.meta.endLine`**: Physical source line range of the block.
  Populated from the logical-line preprocessor output (`llStartLine`). Enables
  navigation to any procedure without grep.
- **`.nodeType`** equivalent: the `"tag"` field on every AST node (already present).

### Source line conventions

- Line numbers are **logical** (after `&` continuation joining), 1-indexed.
- `startLine` = line of the `public function` / `on clicked` / etc. header statement.
- `endLine` = line of the corresponding `end function` / `end on` terminator.
- Column tracking is omitted: PowerScript is line-oriented; column positions inside a
  joined logical line are meaningless for on-disk navigation.

### DataWindow controls

Every `DwControl` node carries:

```json
{
  "meta": {
    "file": "example/openpay-0.1.1b-extract/dw_misth_kratapod_list.srd",
    "dw": "dw_misth_kratapod_list",
    "sourceLine": 88
  }
}
```

### PBSELECT (DataWindow retrieval)

Do not treat `PBSELECT` as a raw text string. Parse it into a typed node:

```json
{
  "retrieve": {
    "version": 400,
    "tables": ["misth_kratapod"],
    "columns": ["misth_kratapod.kodkratapod", "misth_kratapod.kodxrisi"],
    "arguments": [{"name": "arg_kodxrisi", "type": "string"}],
    "where": [
      {"exp1": "misth_kratapod.kodxrisi", "op": "=", "exp2": ":arg_kodxrisi", "logic": null}
    ]
  }
}
```

This enables the `dw_retrieve_tables` fact table in DuckDB, which is the core of the
"what DB tables does this form read?" use case.

### Inline PowerScript SQL & PL/SQL Blocks

Host variables (`:ls_invoice_id`, `:dw_1.Object.Data`) are serialised as
`{"tag":"host_var","lvalue":{...}}` — distinct from regular lvalues so SQL parsers
do not choke on the colon syntax. Currently classified as `ExHostVar` in the AST.

Preserve `//` and `/* */` comments under a `.comments` array attached to the nearest
statement node (deferred to E8 — requires lexer changes).

---

## 4. Scalable Compilation Pipeline

```
[ 1,700 Source Files ]  [ --ddl catalog file(s), optional ]
         │                          │
         ▼  pbc --db FILE  (DuckDB-direct mode — all passes 1-8 in Haskell) ◀───┘
         │  (embedded SQL + DDL text round-trips through a pool of
         │   sql_worker.py subprocesses wrapping sqlglot — see
         │   doc/architecture.md's "SQL/DDL bridge" section)
         ▼
[ pb.duckdb ]  ← written directly by pbc
  ├── objects            (one row per source file / type declaration; ancestry via objects.ancestor)
  ├── source_files / parse_errors
  ├── procedures         (functions, subroutines, events, on-blocks;
  │                        instr_graph_json, wiring_json)
  ├── dw_objects / dw_controls
  ├── dw_retrieve_tables / dw_retrieve_columns / dw_retrieve_where / dw_joins
  ├── sql_statements / sql_statement_columns / sql_statement_filters / sql_statement_tables
  ├── catalog_columns / catalog_pks / catalog_fks / catalog_checks   (DDL catalog, --ddl)
  ├── local_vars / call_sites / global_vars
  ├── proc_defs / proc_uses    (def-use chains)
  ├── resolved_types / resolved_calls
  ├── interproc_edges / procedure_summaries
  ├── taint_sources / taint_sinks / taint_paths / taint_annotations
  ├── dead_code
  ├── schema_objects / schema_morphisms   (DB schema as a free category — Plan 148)
  ├── decomposition_coslice               (per-column rewrite-cost paths — Plan 153 D5)
  └── object_metrics     (PageRank, betweenness, cyclomatic — pb analyze)
         │
         ├──▶  SQL queries (LLM-generated, answers any structural question)
         ├──▶  pb analyze  (NetworkX graph metrics → object_metrics)
         └──▶  pb explore  (FastAPI + SolidJS SPA — interactive analysis UI,
                             incl. /api/diagram* GraphViz rendering)
```

### Serialisation rules

1. **`pbc --db FILE` populates `pb.duckdb` directly.** `pb index` shells
   out to `pbc --db`; Haskell runs all 8 passes and writes every table
   directly.
2. **Embedded SQL and `--ddl` catalogs are parsed via a Python subprocess
   bridge.** `pbc` spawns a pool of `sql_worker.py` processes wrapping
   `sqlglot` over a length-prefixed JSON stdin/stdout protocol; see
   `doc/architecture.md`'s "Haskell ↔ Python: SQL/DDL bridge" section for
   the flags (`--ddl`, `--sql-dialect`, `--sql-worker-python`,
   `--default-namespace`) and wire format.
3. **Tilde-escaping:** Normalise `~"` → `"` and `~~` → `~` in all string values before
   serialisation. The `pbDwStringChunk` lexer function handles this.

---

## 5. Canonical DuckDB Schema

This is the authoritative query contract. LLMs and scripts should target these tables.

This mirrors `compiler/src/PB/Pipeline/DuckDb.hs`'s `initSchema` — the
authoritative source if this list drifts.

```sql
-- One row per source file (or per global type declaration in multi-type files)
objects (file TEXT, kind TEXT, object TEXT, ancestor TEXT, layout_json TEXT,
         type_blocks_json TEXT, confidence TEXT)
source_files (file TEXT PRIMARY KEY, lines TEXT)
parse_errors (file TEXT, error TEXT)

-- Every callable unit: functions, subroutines, events, on-blocks
procedures (
    file TEXT, object TEXT, proc_name TEXT, proc_type TEXT,
    start_line INT, end_line INT,
    cfg_json TEXT,            -- PB.Analysis.Cfg
    instr_graph_json TEXT,    -- PB.Analysis.GraphBuilder / InstrGraph (flat, PC-indexed)
    wiring_json TEXT,         -- PB.Analysis.GraphBuilder's LowCat wiring diagram (Plan 149)
    params TEXT, return_type TEXT,
    cyclomatic INT,           -- McCabe complexity (branches + 1)
    confidence TEXT
    -- Body text lives inside instr_graph_json/wiring_json.
)

-- DataWindow objects + visual controls
dw_objects  (file TEXT, object TEXT, style TEXT, layout_json TEXT, retrieve_sql TEXT)
dw_controls (
    file TEXT, object TEXT, band TEXT, control_type TEXT, name TEXT,
    x INT, y INT, width INT, height INT, expression TEXT
)

-- PBSELECT retrieval decomposition (namespace-aware, Plan 157)
dw_retrieve_tables  (file TEXT, dw_name TEXT, namespace TEXT, table_name TEXT)
dw_retrieve_columns (file TEXT, dw_name TEXT, namespace TEXT, table_name TEXT, column_name TEXT)
dw_retrieve_where   (file TEXT, dw_name TEXT, idx INT, exp1 TEXT, op TEXT, exp2 TEXT, logic TEXT)
dw_joins            (file TEXT, dw_name TEXT, left_ref TEXT, op TEXT, right_ref TEXT,
                      outer1 TEXT, outer2 TEXT)

-- Embedded SQL per procedure, plus per-column/filter/table attribution
sql_statements         (file TEXT, object TEXT, proc_name TEXT, line INT,
                         operation TEXT, tables TEXT, columns TEXT, raw_sql TEXT, parse_ok BOOLEAN)
sql_statement_columns  (file TEXT, object TEXT, proc_name TEXT, line INT,
                         namespace TEXT, table_name TEXT, column_name TEXT, is_write BOOLEAN)
sql_statement_filters  (file TEXT, object TEXT, proc_name TEXT, line INT,
                         namespace TEXT, table_name TEXT, column_name TEXT, op TEXT, values_json TEXT)
sql_statement_tables   (file TEXT, object TEXT, proc_name TEXT, line INT,
                         operation TEXT, namespace TEXT, table_name TEXT)
all_sql_tables         -- VIEW: UNION of dw_retrieve_tables + sql_statement_tables, one row shape

-- Static DDL catalog (populated from --ddl files via the sqlglot bridge)
catalog_columns (namespace TEXT, table_name TEXT, column_name TEXT, ordinal INT)
catalog_pks     (namespace TEXT, table_name TEXT, column_name TEXT, ordinal INT)
catalog_fks     (constraint_name TEXT, from_namespace TEXT, from_table TEXT, from_column TEXT,
                  to_namespace TEXT, to_table TEXT, to_column TEXT, ordinal INT)
catalog_checks  (constraint_name TEXT, namespace TEXT, table_name TEXT, predicate TEXT)

-- Intra-procedural def-use + cross-file type/call resolution
local_vars      (file TEXT, object TEXT, proc_name TEXT, var_name TEXT, raw_type TEXT,
                  is_param BOOLEAN, scope_line INT)
call_sites      (file TEXT, object TEXT, proc_name TEXT, to_name TEXT, call_type TEXT, line INT)
global_vars     (file TEXT, object TEXT, var_name TEXT, var_type TEXT, mods TEXT)
proc_defs       (file TEXT, object TEXT, proc_name TEXT, var_name TEXT, block_id TEXT,
                  stmt_index INT, line INT, kind TEXT)
proc_uses       (file TEXT, object TEXT, proc_name TEXT, var_name TEXT, block_id TEXT,
                  stmt_index INT, line INT, kind TEXT)
resolved_types  (file TEXT, object TEXT, proc_name TEXT, var_name TEXT, raw_type TEXT,
                  kind TEXT, target TEXT, is_param BOOLEAN, scope_line INT)
resolved_calls  (file TEXT, object TEXT, proc_name TEXT, to_name TEXT, call_type TEXT, line INT,
                  target_object TEXT, target_proc TEXT, kind TEXT, confidence TEXT)

-- Inter-procedural taint analysis
interproc_edges     (caller_object TEXT, caller_proc TEXT, caller_line INT,
                      callee_object TEXT, callee_proc TEXT, edge_kind TEXT, var_name TEXT,
                      caller_context TEXT, callee_context TEXT)
procedure_summaries (file TEXT, object TEXT, proc_name TEXT, params_in TEXT,
                      globals_read TEXT, globals_written TEXT, return_flows_to TEXT)
taint_sources        (file TEXT, object TEXT, proc_name TEXT, var_name TEXT, source_type TEXT, line INT)
taint_sinks          (file TEXT, object TEXT, proc_name TEXT, var_name TEXT, sink_type TEXT,
                       severity TEXT, line INT)
taint_paths          (file TEXT, object TEXT, proc_name TEXT, var_name TEXT,
                       target_file TEXT, target_object TEXT, target_proc TEXT, target_var TEXT,
                       severity TEXT, category TEXT, steps_json TEXT)
taint_annotations    (file TEXT, object TEXT, proc_name TEXT, block_id TEXT,
                       is_taint_entry BOOLEAN, is_taint_sink BOOLEAN, tainted_vars TEXT)

dead_code (object TEXT, proc_name TEXT, proc_type TEXT, cyclomatic INT, confidence TEXT,
           caller_count_naive INT, caller_count_scoped INT)

-- DB schema as a free category (Plan 148): objects are (table,column) pairs and
-- SQL-statement/DW-retrieve instances; morphisms are the legs a statement has into
-- the columns it touches, plus FK morphisms from DW JOINs and DDL foreign keys.
schema_objects   (object_key TEXT, kind TEXT, namespace TEXT, table_name TEXT, column_name TEXT,
                   stmt_file TEXT, stmt_object TEXT, stmt_proc TEXT, stmt_line INT)
schema_morphisms (from_key TEXT, to_key TEXT, leg_kind TEXT, fk_source TEXT)

-- Per-column "rewrite cost": union of forward blast-radius + backward validation-walk,
-- collapsed to the shortest path per reachable statement (Plan 153 D5)
decomposition_coslice (seed_key TEXT, target_key TEXT, direction TEXT, leg_ordinal INT,
                        leg_from TEXT, leg_to TEXT, leg_kind TEXT, fk_source TEXT)

-- Inheritance is `objects.ancestor` (walked via a recursive CTE, see the
-- example query below); the call graph is `call_sites` (raw) /
-- `resolved_calls` (cross-file resolved) above.

-- Pre-computed graph metrics (populated by `pb analyze`, Python/NetworkX;
-- schema DDL owned by `db.py:setup_db_extras`)
object_metrics (
    object TEXT, in_degree INT, out_degree INT,
    betweenness DOUBLE, pagerank DOUBLE,
    max_cyclomatic INT, avg_cyclomatic DOUBLE, dit INT, cbo INT
)
```

### Example canonical queries

Note: `objects` holds PowerScript objects only (`.srw`/`.sru`/`.srf`/…);
DataWindow files (`.srd`) are separate rows in `dw_objects`, keyed by
`dw_name` in the `dw_*` tables — there is no `objects` row to join against
for a DW by file path.

```sql
-- What DB tables does a given DataWindow retrieve from?
SELECT DISTINCT dt.namespace, dt.table_name
FROM dw_retrieve_tables dt
WHERE dt.dw_name = 'd_invoice_detail';

-- Full inheritance chain for an object
WITH RECURSIVE anc AS (
  SELECT object, ancestor FROM objects WHERE object = 'w_invoice_entry'
  UNION ALL
  SELECT o.object, o.ancestor FROM objects o
    JOIN anc a ON o.object = a.ancestor WHERE o.ancestor IS NOT NULL
)
SELECT * FROM anc;

-- Top 10 complexity hotspots
SELECT o.object, m.max_cyclomatic, m.in_degree, m.pagerank
FROM objects o JOIN object_metrics m ON o.object = m.object
ORDER BY m.max_cyclomatic DESC LIMIT 10;

-- All compute expressions referencing a specific DB function
SELECT file, object, name AS control_name, expression
FROM dw_controls
WHERE expression LIKE '%fn_misth%';
```

---

## 6. Tool Reference

| Tool | Language | Input | Output |
|---|---|---|---|
| `pbc --db FILE [--ddl [SCHEMA:]FILE]... [--sql-dialect D] [--sql-worker-python BIN] [--default-namespace NS]` | Haskell | source dir (+ optional DDL files) | pb.duckdb (all passes 1–8) |
| `sql_worker.py` (bridge) | Python, subprocess pool spawned by `pbc` | SQL/DDL text over stdin (length-prefixed JSON) | sqlglot-parsed columns/tables/catalog over stdout |
| `pb index` | Python (CLI) | source dir | pb.duckdb — drives `pbc --db` directly, plus incremental-state bookkeeping |
| `pb analyze` | Python (CLI) | pb.duckdb | object_metrics table (NetworkX: PageRank, betweenness, DIT) |
| `pb explore` | Python + TS | pb.duckdb | FastAPI (`cli/api/`) + SolidJS SPA (`ui/`), incl. `/api/diagram*` for GraphViz SVG rendering |
| `pb check-corpus` | Python (CLI) | source dir | pass/fail gate: 0 parse errors expected |
| `pb dead-code` / `pb impact` / `pb clean` | Python (CLI) | pb.duckdb | terminal reports |
