# PowerBuilder Codebase Analysis

[![CI](https://github.com/thomasmarsh/pb/actions/workflows/ci.yml/badge.svg)](https://github.com/thomasmarsh/pb/actions/workflows/ci.yml)

Explore a PowerBuilder codebase through an interactive web UI —
browse objects, trace call graphs, inspect DataWindows, and query
relationships without grepping or manual reading. Backed by a DuckDB
database, you can also run SQL directly or hand the schema to an LLM.

```mermaid
%%{init: {'themeVariables': {'edgeLabelBackground': 'transparent'}}}%%
flowchart LR
    src(["📂 .pbl files"])
    pipeline(["⚙ pb index"])
    db[("pb.duckdb")]
    explore(["🌐 pb explore"])

    src --> pipeline
    pipeline -- "parse → import → analyze" --> db
    db --> explore

    classDef src fill:#546e7a,stroke:#90a4ae,color:#fff
    classDef cmd fill:#1565c0,stroke:#90caf9,color:#fff
    classDef db  fill:#37474f,stroke:#90a4ae,color:#fff

    class src src
    class pipeline cmd
    class db db
    class explore cmd
```

---

## Quick start

**Prerequisites:** [GHCup](https://www.haskell.org/ghcup/) (installs GHC + Cabal), [pnpm](https://pnpm.io/), and [uv](https://docs.astral.sh/uv/).

```bash
# Index and explore in one step — incremental by default
./pb explore /path/to/src     # builds, indexes, and opens browser
```

Or separately:

```bash
./pb index /path/to/src       # parse → import → analyze
./pb explore                  # open browser (reuses existing pb.duckdb)
```

On the first run the Haskell parser is built automatically. Every subsequent
run only re-parses files whose content has changed — unchanged files are
skipped instantly.

Input can be a directory of `.sr*` source files, a single `.pbl` library
file, or a directory of `.pbl` files — extraction happens transparently,
no separate `pb extract` step required.

---

## Explorer (web UI)

The interactive explorer is a SolidJS SPA backed by a FastAPI server and DuckDB.

```bash
# Index + explore in one step (zero-config)
./pb explore /path/to/src

# Just open the explorer (requires pb.duckdb to already exist)
./pb explore

# Explicit options
./pb explore --db pb.duckdb --port 8000
```

### What you can do

| View        | What it shows                                                   |
| ----------- | --------------------------------------------------------------- |
| Dashboard   | Codebase overview — metrics, charts, health                     |
| Objects     | Browse all parsed objects with detail views                     |
| Procedures  | Functions, subroutines, events — full AST body rendering        |
| DataWindows | Controls, bands, retrieval args, SQL lineage                    |
| Tables      | Database tables referenced by DataWindows                       |
| Diagrams    | Inheritance, call graphs, DW-table deps, heatmaps (interactive) |
| Queries     | Run canned SQL queries or write your own                        |
| Search      | Full-text search across objects and procedures                  |
| Explore     | Write and run ad-hoc SQL against the database                   |

---

## CLI reference

```
pb explore [DIR] [--db DB]   Index DIR (if given), then start the web UI.
pb index DIR [--db DB]       Parse → import → analyze (incremental).
pb index DIR --reset         Full re-parse, drop and recreate all tables.
pb dump DIR -o OUTDIR        Parse to a mirrored JSON file tree (one-shot).
pb analyze [DB]              Re-run graph metrics on an existing database.
pb extract DIR -o OUTDIR     Extract .pbl library files to per-library dirs.
```

`pb index` prints a progress bar while parsing, shows rich error panels for any
files that fail (with source context), and reports a summary on stderr.

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

- **[`doc/architecture.md`](doc/architecture.md)** — component map, data flow, cross-component
  interfaces, testing, and build sequence.
- **[`doc/vision.md`](doc/vision.md)** — architectural rationale, LLM integration workflow,
  DuckDB schema design, and the full operational pipeline.
- **[`doc/spec.md`](doc/spec.md)** — parser specification: lexical rules, token forms,
  file structure, DataWindow syntax.
- **[`doc/development.md`](doc/development.md)** — build overview, test commands, adding
  queries, and corpus/debt analysis.
- **`CLAUDE.md`** — development protocol: staged verification loop, corpus
  gates, module placement guide, and code index.
