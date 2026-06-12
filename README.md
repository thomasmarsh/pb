# pb — PowerBuilder codebase intelligence

Parse a legacy PowerBuilder source tree into a DuckDB relational database
you can query with plain SQL, or hand to an LLM as a tool. This avoids
the need for grepping or manual reading.

```
pb-runner parses .sr* files → JSONL stream → pb index → pb.duckdb
                                                     ↓
              SQL queries  ←  fact tables  →  pb analyze  →  pb diagram
```

---

## Quick start

```bash
# 1. Build the parser (Haskell + cabal)
cabal build pb-runner

# 2. Install Python tooling
uv sync

# 3. Parse and index your source tree in one pipeline
cabal run pb-runner -- -i /path/to/src --jsonl | uv run pb index

# 4. Compute graph metrics (call graph, cyclomatic complexity, PageRank)
uv run pb analyze

# 5. Query
duckdb pb.duckdb
```

`pb.duckdb` now contains every object, procedure, DataWindow
control, database reference, and inheritance edge in your codebase.

---

## Fact tables

| Table                 | Rows (example)                               | What's in it                                                    |
| --------------------- | -------------------------------------------- | --------------------------------------------------------------- |
| `objects`             | one per source file                          | name, kind (`powerscript`/`datawindow`), declared ancestor      |
| `procedures`          | functions + subroutines + events + on-blocks | name, modifiers, params, return type, start/end line, body JSON |
| `inherits`            | one per ancestor declaration                 | `from_object → to_object` edges                                 |
| `calls`               | call graph edges                             | `object → to_name`, call type; populated by `pb analyze`        |
| `object_metrics`      | one per object                               | PageRank, betweenness, in/out degree, max cyclomatic, DIT       |
| `dw_controls`         | one per DataWindow control                   | type, band, x/y/width/height, expression, tab order             |
| `dw_retrieve_tables`  | one per table referenced in PBSELECT         | which DataWindow reads which DB table                           |
| `dw_retrieve_columns` | one per column in SELECT list                | fully-qualified `table.column`                                  |
| `dw_retrieve_where`   | one per WHERE clause condition               | `exp1 op exp2 logic`                                            |
| `dw_arguments`        | one per retrieval argument                   | name, type                                                      |

---

## Queries

Open a shell: `duckdb pb.duckdb`

### Most complex procedures

```sql
SELECT object, name, proc_type, cyclomatic
FROM procedures
ORDER BY cyclomatic DESC
LIMIT 15;
```

```
object               name             proc_type  cyclomatic
w_app                doubleclicked    event      29
w_krat_total_search  of_createwhere   function   17
w_pbgrid             me_delrec        event      13
...
```

### Most important objects (PageRank)

Higher PageRank = more of the codebase depends on this object, directly or
transitively. The first place to look when planning a refactor.

```sql
SELECT object, pagerank, in_degree, out_degree, max_cyclomatic
FROM object_metrics
ORDER BY pagerank DESC
LIMIT 10;
```

### God objects — high complexity AND high fan-in

```sql
SELECT m.object, m.in_degree, m.max_cyclomatic, m.avg_cyclomatic,
       count(p.name) AS proc_count
FROM object_metrics m
JOIN procedures p ON p.object = m.object
GROUP BY m.object, m.in_degree, m.max_cyclomatic, m.avg_cyclomatic
HAVING m.in_degree >= 5 AND m.max_cyclomatic >= 3
ORDER BY m.in_degree * m.max_cyclomatic DESC;
```

Scale the thresholds to your codebase size. For the bundled `example/openpay`
corpus `>= 5` and `>= 3` are appropriate; larger codebases may want `> 10 / > 10`.

### Who calls this function?

```sql
SELECT DISTINCT object AS caller, from_proc, call_type
FROM calls
WHERE to_name = 'fn_sqlerror'
ORDER BY caller;
```

### Dead code candidates — procedures never called

```sql
SELECT p.object, p.proc_type, p.name, p.start_line
FROM procedures p
LEFT JOIN calls c ON c.to_name = p.name
WHERE c.to_name IS NULL
  AND p.proc_type IN ('function', 'subroutine')
  AND p.modifiers NOT LIKE '%public%'
ORDER BY p.object, p.name;
```

### What database tables does a DataWindow read?

```sql
SELECT dt.dw_name, dt.table_name,
       string_agg(dc.column_name, ', ' ORDER BY dc.column_name) AS columns
FROM dw_retrieve_tables dt
JOIN dw_retrieve_columns dc
  ON dc.dw_name = dt.dw_name AND dc.table_name = dt.table_name
WHERE dt.dw_name = 'dw_misth_ypal_yvar_list'
GROUP BY dt.dw_name, dt.table_name;
```

### Which forms read from a specific database table?

```sql
SELECT DISTINCT dt.dw_name, dt.file
FROM dw_retrieve_tables dt
WHERE dt.table_name = 'misth_ypal'
ORDER BY dt.dw_name;
```

### DataWindows with parameterised retrieval (retrieval arguments)

```sql
SELECT da.dw_name, da.arg_name, da.arg_type,
       string_agg(dw.exp1 || ' ' || dw.op || ' ' || dw.exp2, ' AND ')
         AS where_clause
FROM dw_arguments da
JOIN dw_retrieve_where dw ON dw.dw_name = da.dw_name
WHERE da.dw_name = 'dw_misth_ypal_yvar_list'
GROUP BY da.dw_name, da.arg_name, da.arg_type
ORDER BY da.dw_name;
```

### Full inheritance chain for an object

```sql
WITH RECURSIVE chain AS (
    SELECT from_object AS obj, to_object AS parent, 1 AS depth
    FROM inherits
    WHERE from_object = 'm_misth_zpstath_grid'
  UNION ALL
    SELECT chain.obj, i.to_object, chain.depth + 1
    FROM inherits i
    JOIN chain ON chain.parent = i.from_object
)
SELECT depth, parent FROM chain ORDER BY depth;
```

### All descendants of a base class

```sql
WITH RECURSIVE sub AS (
    SELECT from_object, to_object FROM inherits WHERE to_object = 'w_list'
  UNION ALL
    SELECT i.from_object, i.to_object
    FROM inherits i JOIN sub ON i.to_object = sub.from_object
)
SELECT DISTINCT from_object AS descendant FROM sub ORDER BY 1;
```

### Objects with the deepest inheritance tree

```sql
SELECT object, dit
FROM object_metrics
WHERE dit IS NOT NULL
ORDER BY dit DESC
LIMIT 10;
```

### Database table coverage — which tables are referenced across the whole codebase

```sql
SELECT table_name,
       count(DISTINCT dw_name) AS datawindow_count,
       string_agg(DISTINCT dw_name, ', ') AS datawindows
FROM dw_retrieve_tables
GROUP BY table_name
ORDER BY datawindow_count DESC;
```

### Procedures larger than N lines

```sql
SELECT object, proc_type, name, start_line, end_line,
       (end_line - start_line) AS line_count
FROM procedures
WHERE end_line IS NOT NULL
ORDER BY line_count DESC
LIMIT 20;
```

### Cross-object coupling — which object pairs call each other most?

```sql
SELECT c.object AS caller, c.to_name AS callee, count(*) AS edge_count
FROM calls c
WHERE c.object != c.to_name
GROUP BY c.object, c.to_name
HAVING count(*) > 3
ORDER BY edge_count DESC
LIMIT 20;
```

---

## Diagrams

Requires `pb.duckdb` populated with `pb analyze` first.

```bash
# Inheritance hierarchy (all objects)
uv run pb diagram inheritance -o inheritance.svg

# Call ego-graph centred on a high-PageRank object
uv run pb diagram calls --object nvo_validation --depth 2 -o calls.svg

# DataWindow → DB table bipartite dependency graph
uv run pb diagram dw-tables -o dw_tables.svg

# Complexity heatmap (all objects, size = fan-in, colour = cyclomatic)
uv run pb diagram heatmap -o heatmap.svg

# Emit raw DOT source for any diagram (pipe to dot or graphviz tools)
uv run pb diagram inheritance --dot | dot -Tpng > inheritance.png
```

---

## Debt analysis

Measure how much of the AST is still in raw fallback form (unclassified
statements and expressions). Useful for tracking parser coverage.

```bash
uv run pb debt --no-build   # skips cabal build if pb-runner is already fresh
```

---

## Parser coverage check

```bash
bash scripts/check-corpus.sh   # 0 errors / 777 files = baseline
```

---

## File types parsed

| Extension | Object type      |
| --------- | ---------------- |
| `.srw`    | Application      |
| `.srs`    | Window           |
| `.sru`    | UserObject       |
| `.srf`    | Function         |
| `.srm`    | Menu             |
| `.srd`    | DataWindow       |
| `.sra`    | Structure        |
| `.sro`    | Object (generic) |

---

## Further reading

- **`VISION.md`** — architectural rationale, LLM integration workflow, schema
  design decisions, and the full operational pipeline.
- **`CLAUDE.md`** — development protocol: staged verification loop, corpus
  gates, module placement guide, and code index.
