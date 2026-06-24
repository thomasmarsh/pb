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
- **The LLM reads pseudo-PBScript, not JSON:** The `pb-render` tool converts any
  function or event body from the AST back to readable PowerScript, reducing context
  token cost and hallucination risk.
- **Diagrams communicate structure:** `pb-diagram` generates GraphViz SVGs for
  inheritance hierarchies, call graphs, DW-table dependencies, and complexity heatmaps.

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
                           pb-render shows code body;
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
4. **Render (optional):** The LLM calls `pb-render --object X --proc itemchanged` to get
   a readable pseudo-PBScript body for any procedure in the result set.
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

```bash
pb-runner --render -i ./src --object w_invoice_entry --proc itemchanged
```

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
[ 1,700 Source Files ]
         │
         ▼  pb-runner --db FILE  (DuckDB-direct mode — all passes 1-8 in Haskell)
[ pb.duckdb ]  ← written directly; no JSON intermediate
         │
         │  (alternative: pb-runner --jsonl | pb index — JSONL streaming mode)
         │
[ pb.duckdb ]
  ├── objects            (one row per source file / type declaration)
  ├── procedures         (functions, subroutines, events, on-blocks; cps_graph_json)
  ├── dw_objects / dw_controls / dw_retrieve_*
  ├── sql_statements     (embedded SQL per procedure)
  ├── local_vars / call_sites / global_vars
  ├── proc_defs / proc_uses    (def-use chains)
  ├── resolved_types / resolved_calls / global_vars
  ├── interproc_edges / procedure_summaries
  ├── taint_sources / taint_sinks / taint_paths / taint_annotations
  ├── dead_code
  ├── inherits           (declared ancestry edges)
  ├── calls              (raw call graph edges)
  └── object_metrics     (PageRank, betweenness, cyclomatic — pb analyze)
         │
         ├──▶  SQL queries (LLM-generated, answers any structural question)
         ├──▶  pb analyze  (NetworkX graph metrics → object_metrics)
         ├──▶  pb diagram  (GraphViz SVG: inheritance, calls, DW-tables, heatmap)
         └──▶  pb explore  (FastAPI + SolidJS SPA — interactive analysis UI)
```

### Serialisation rules

1. **Do not generate one giant JSON file.** Use per-file `.json` output (`-o` mode) or
   streaming JSONL (`--jsonl` mode). DuckDB `read_ndjson_auto` can query JSONL directly
   without loading all files into memory.
2. **JSONL for bulk processing:** `pb-runner --jsonl | uv run pb import`
   populates `pb.duckdb` in a single streaming pass.
3. **Tilde-escaping:** Normalise `~"` → `"` and `~~` → `~` in all string values before
   serialisation. The `pbDwStringChunk` lexer function handles this.

---

## 5. Canonical DuckDB Schema

This is the authoritative query contract. LLMs and scripts should target these tables.

```sql
-- One row per source file (or per global type declaration in multi-type files)
objects (file TEXT, name TEXT, kind TEXT, ancestor TEXT)

-- Every callable unit: functions, subroutines, events, on-blocks
procedures (
    file TEXT, object TEXT, proc_type TEXT, name TEXT,
    modifiers TEXT, params TEXT, return_type TEXT,
    start_line INT, end_line INT,
    cyclomatic INT,         -- McCabe complexity (branches + 1)
    body_json JSON          -- full body for ad-hoc inspection / pb-render
)

-- DataWindow visual controls
dw_controls (
    file TEXT, dw_name TEXT, control_name TEXT, control_type TEXT,
    band TEXT, x INT, y INT, width INT, height INT,
    expression TEXT, tab_seq INT, source_line INT
)

-- PBSELECT retrieval decomposition
dw_retrieve_tables  (file TEXT, dw_name TEXT, table_name TEXT)
dw_retrieve_columns (file TEXT, dw_name TEXT, column_fqn TEXT, table_name TEXT, column_name TEXT)
dw_retrieve_where   (file TEXT, dw_name TEXT, idx INT, exp1 TEXT, op TEXT, exp2 TEXT, logic TEXT)
dw_arguments        (file TEXT, dw_name TEXT, arg_name TEXT, arg_type TEXT)

-- Graph edges
inherits (from_object TEXT, to_object TEXT)
calls    (file TEXT, object TEXT, from_proc TEXT, to_name TEXT, call_type TEXT)

-- Pre-computed graph metrics (populated by pb-analyze)
object_metrics (
    object TEXT, in_degree INT, out_degree INT,
    betweenness DOUBLE, pagerank DOUBLE,
    max_cyclomatic INT, avg_cyclomatic DOUBLE, dit INT
)
```

### Example canonical queries

```sql
-- What DB tables does w_invoice_entry read?
SELECT DISTINCT dt.table_name
FROM objects o
JOIN dw_retrieve_tables dt ON o.file = dt.file
WHERE o.name = 'w_invoice_entry';

-- Full inheritance chain for an object
WITH RECURSIVE anc AS (
  SELECT name, ancestor FROM objects WHERE name = 'w_invoice_entry'
  UNION ALL
  SELECT o.name, o.ancestor FROM objects o
    JOIN anc a ON o.name = a.ancestor WHERE o.ancestor IS NOT NULL
)
SELECT * FROM anc;

-- Top 10 complexity hotspots
SELECT o.name, m.max_cyclomatic, m.in_degree, m.pagerank
FROM objects o JOIN object_metrics m ON o.name = m.object
ORDER BY m.max_cyclomatic DESC LIMIT 10;

-- All compute expressions referencing a specific DB function
SELECT file, dw_name, control_name, expression
FROM dw_controls
WHERE expression LIKE '%fn_misth%';
```

---

## 6. Tool Reference

| Tool | Language | Input | Output |
|---|---|---|---|
| `pb-runner --db FILE` | Haskell | source dir | pb.duckdb (all passes 1–8) |
| `pb-runner --jsonl` | Haskell | source dir | JSONL stream (legacy) |
| `pb-runner -o DIR` | Haskell | source dir | per-file JSON + manifest.json (legacy) |
| `pb index` | Python | JSONL | pb.duckdb (JSONL ingestion path) |
| `pb analyze` | Python | pb.duckdb | object_metrics table |
| `pb diagram` | Python | pb.duckdb | GraphViz SVG |
| `pb explore` | Python + TS | pb.duckdb | FastAPI + SolidJS SPA |
