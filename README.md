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
uv run pb top              # most complex procedures
uv run pb pagerank         # most important objects
uv run pb --help           # full command list
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

Built-in commands cover the most common analyses — no SQL required:

```bash
uv run pb top                              # most complex procedures
uv run pb pagerank                         # most important objects by PageRank
uv run pb callers fn_sqlerror             # who calls this function
uv run pb dead-code                        # uncalled non-public procedures
uv run pb god-objects                      # high fan-in + high complexity
uv run pb ancestors m_misth_zpstath_grid  # inheritance chain upward
uv run pb descendants w_list              # all objects extending w_list
uv run pb dw dw_misth_ypal_yvar_list      # tables/columns for a DataWindow
uv run pb db-coverage                     # all referenced database tables
uv run pb coupling                        # most tightly coupled object pairs
```

Most commands accept `--n` to change the row limit and `--db` to target a
different database file. Run `uv run pb <command> --help` for details.

### Adding queries

Drop a `.sql` file into `queries/` and it becomes a `pb` command automatically.
The leading comment block sets the description and parameters:

```sql
-- One-line description shown in pb --help.
-- :name TEXT          ← required positional argument
-- :n INT 20           ← optional --n flag with default 20
SELECT ...
WHERE col = $name
LIMIT $n;
```

### Ad-hoc SQL

For queries not covered by the built-ins, open a DuckDB shell directly:

```bash
duckdb pb.duckdb
```

```sql
-- Procedures larger than N lines
SELECT object, proc_type, name, start_line, end_line,
       (end_line - start_line) AS line_count
FROM procedures
WHERE end_line IS NOT NULL
ORDER BY line_count DESC
LIMIT 20;

-- DataWindows with parameterised retrieval
SELECT da.dw_name, da.arg_name, da.arg_type,
       string_agg(dw.exp1 || ' ' || dw.op || ' ' || dw.exp2, ' AND ') AS where_clause
FROM dw_arguments da
JOIN dw_retrieve_where dw ON dw.dw_name = da.dw_name
GROUP BY da.dw_name, da.arg_name, da.arg_type
ORDER BY da.dw_name;

-- Objects with the deepest inheritance tree
SELECT object, dit FROM object_metrics
WHERE dit IS NOT NULL ORDER BY dit DESC LIMIT 10;
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
