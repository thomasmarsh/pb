# CLI Architecture

This document describes the three-layer architecture of `pb_cli/`, the
dependency rules that keep it testable, and how to add new modules without
violating the invariants.

---

## Overview

The CLI is organised into three layers, each with a single responsibility:

```
┌─────────────────────────────────────────────────────┐
│  explorer/  — FastAPI web layer                      │
│  routes thin → services contain logic                │
├─────────────────────────────────────────────────────┤
│  shell/     — Imperative boundary                    │
│  filesystem, subprocess, DB, display                 │
├─────────────────────────────────────────────────────┤
│  core/      — Pure data transforms                   │
│  parsers, walkers, models, SQL pre-processing        │
└─────────────────────────────────────────────────────┘
```

**`core/`** holds everything that can be unit-tested with literal Python
values — no I/O, no network, no subprocess calls, no framework imports.
This is the functional core.

**`shell/`** is the imperative boundary. It owns all side-effecting
operations: filesystem reads, `pb-runner` subprocess invocation, DuckDB
connections, and rich console output. Every side effect flows through
`ShellEnv` closures, making them swappable in tests.

**`explorer/`** is a thin FastAPI web layer. Routes extract parameters and
delegate to services. Services contain the business logic. Both import
from `core/` for pure data and from `shell/` (or `shell/db.py` directly)
for database access.

**`cli.py`** is a thin Typer dispatch that wires commands to
`shell/commands/` implementations. It imports nothing from `core/` or
`explorer/` directly (except the `pbl` extraction helper).

---

## Dependency rules

The import graph is strictly layered:

| Import direction | Allowed? | Example |
|---|---|---|
| `core/` → `shell/` | **No** | Never |
| `core/` → `explorer/` | **No** | Never |
| `shell/` → `core/` | **Yes** | `shell/importing.py` imports `core/importing.py` |
| `explorer/` → `core/` | **Yes** | `explorer/services/` imports `core/models.py` |
| `explorer/` → `shell/` | **Yes** | `explorer/routes/dependencies.py` connects to DuckDB |
| `cli.py` → `shell/` | **Yes** | `cli.py` imports `shell/env.py`, `shell/commands/` |
| `cli.py` → `explorer/` | **Yes** | Only `from pb_cli.explorer import create_app` |

Violating these rules creates import cycles or makes pure-core modules
untestable without mocking I/O frameworks.

---

## The `ShellEnv` pattern

`shell/env.py` defines a composition of three domain-specific environments
on a single top-level dataclass:

```python
@dataclass
class ShellEnv:
    build:    BuildEnv    = field(default_factory=BuildEnv)
    runner:   RunnerEnv   = field(default_factory=RunnerEnv)
    storage:  StorageEnv  = field(default_factory=StorageEnv)
    reporter: Reporter    = field(default_factory=LiveReporter)

env = ShellEnv()
```

Each sub-environment groups related side-effecting operations behind typed
fields:

### `BuildEnv` (8 fields)
Repo discovery, binary builds, file enumeration, source hashing, and
explorer build management. Fields: `find_repo`, `get_queries_dir`,
`find_binary`, `build_runner`, `walk_sr_files`, `count_sr_files`,
`hash_source_dir`, `ensure_explorer_built`.

### `RunnerEnv` (2 fields)
Parsing via the `pb-runner` Haskell binary and rich error rendering.
Fields: `parse_stream`, `render_error`.

### `StorageEnv` (15 fields)
DuckDB connection management, schema DDL, incremental state tracking,
batch import, and metric computation.
Fields: `db_connection`, `create_schema`, `drop_tables`,
`create_state_table`, `load_file_state`, `delete_file_rows`,
`save_file_state`, `build_subset_tmpdir`, `import_batch`,
`run_from_jsonl_lines`, `compute_dit`, `compute_metrics`, `connect`.

### `reporter`
A `Reporter` protocol instance (default: `LiveReporter`). Alternatives
include `RecordingReporter` for test fixtures.

### Why closures, not direct imports

Every field is a callable closure — a function that takes plain data in and
returns plain data out, but reaches the filesystem, a subprocess, or the
network to do it. The global `env` instance is constructed with real
implementations at module load time. In tests, you replace individual
fields on a copy:

```python
from dataclasses import replace
from pb_cli.shell.env import ShellEnv
from pb_cli.shell.runner import parse_stream  # real implementation

test_env = ShellEnv(
    runner=replace(env.runner, parse_stream=my_mock_stream),
)
```

### Protocol vs Callable annotations

Fields whose real function has keyword-only parameters or defaults that
call sites rely on use a `Protocol` class preserving the full signature
(e.g., `ParseStream`, `FindRepo`, `BuildRunner`, `EnsureExplorerBuilt`,
`DbConnection`, `ImportBatch`, `RunFromJsonlLines`). All other fields use
plain `Callable[[...], ...]` annotations — pyright still checks the
assigned function against the field's type, but no class boilerplate is
needed where the real signature adds nothing a `Callable` cannot express.

---

## Module reference

### `core/` — Pure transforms (zero I/O)

| Module | Purpose | Key exports |
|---|---|---|
| `models.py` | Row types (`NamedTuple`) and `RowBatch` container | `ObjectRow`, `ProcedureRow`, `CallRow`, `DwControlRow`, `SqlStatementRow`, `InheritsRow`, `RowBatch`, `new_row_batch`, `TABLES` |
| `ast_walker.py` | Recursive walkers over parsed AST JSON | `walk_calls`, `walk_exraw`, `walk_bsraw`, `count_branches`, `walk_dw_controls` |
| `importing.py` | JSON → `RowBatch` transforms | `import_file` |
| `sql.py` | PowerBuilder SQL parser (wraps sqlglot with PB-specific rewrites) | `parse_pb_sql` |
| `state.py` | Pure file-state diffing | `FileDiff`, `diff_state` |
| `categorize.py` | Keyword-driven classification of BsRaw statement text | `categorize`, `SQL_KWS`, `DW_STRUCT_FIELDS` |
| `diagram_builder.py` | Pure diagram styling and GraphViz render functions | `render_calls`, `render_dw_tables`, `render_heatmap`, `render_inheritance`, `render_proc_tables`, `render_sql_lineage`, `render_table_lineage`, `KIND_COLORS`, `GRAPH_ATTRS` |

### `shell/` — Imperative boundary (I/O-bound)

| Module | Purpose | Key exports |
|---|---|---|
| `env.py` | `ShellEnv` composition pattern (BuildEnv / RunnerEnv / StorageEnv) | `ShellEnv`, `env`, `BuildEnv`, `RunnerEnv`, `StorageEnv` |
| `build.py` | Repo discovery, `pb-runner` binary build, file enumeration | `find_repo`, `build_runner`, `find_binary`, `walk_sr_files`, `count_sr_files`, `hash_source_dir`, `ensure_explorer_built`, `build_subset_tmpdir`, `get_queries_dir` |
| `runner.py` | Stream parse results from `pb-runner --jsonl` | `parse_stream`, `render_error` |
| `db.py` | DuckDB schema DDL, connection management, query parsing | `db_connection`, `connect`, `create_schema`, `drop_tables`, `Conn`, `INSERT`, `parse_sql_file` |
| `importing.py` | Batch import of parsed file dicts into DuckDB | `import_batch`, `run_from_jsonl_lines` |
| `state.py` | Incremental file-state persistence (DB-backed) | `create_state_table`, `load_file_state`, `save_file_state`, `delete_file_rows` |
| `metrics.py` | Graph metric computation (PageRank, betweenness, DIT) | `compute_metrics`, `compute_dit` |
| `diagrams.py` | DOT/SVG diagram building, LRU-cached rendering with Bezier fallback | `render_svg`, `build_inheritance`, `build_calls`, `build_dw_tables`, `build_heatmap`, `build_sql_lineage`, `build_table_lineage`, `build_proc_tables` |
| `pipeline.py` | Incremental `pb index` orchestration | `run`, `db_is_current` |
| `pbl.py` | PBL binary library extraction (filesystem, temp dirs, file writes) | `extract`, `extract_to_dir`, `resolve_source_dir`, `PblEntry` |
| `reporter.py` | Unified output protocol for pipeline operations | `Reporter`, `LiveReporter`, `RecordingReporter` |
| `queries.py` | Auto-register `queries/*.sql` files as `pb query <name>` commands | `register_queries` |
| `commands/corpus.py` | `pb check-corpus` implementation | `run` |
| `commands/debt.py` | `pb debt` implementation | `run`, `BsRawStats`, `DwStats` |
| `commands/dump.py` | `pb dump` implementation | `run` |

### `explorer/` — FastAPI web layer

| Module | Purpose | Key exports |
|---|---|---|
| `app.py` | FastAPI application factory, router registration, SPA fallback | `create_app` |
| `routes/dependencies.py` | Shared DB connection dependency and `rows()` helper | `get_db`, `get_conn`, `rows` |
| `routes/objects.py` | Object listing, detail, source, explore tree endpoints | Router: `/api/objects`, `/api/objects/{name}`, `/api/source`, `/api/tree` |
| `routes/procedures.py` | Procedure listing and detail endpoints | Router: `/api/procedures` |
| `routes/search.py` | Full-text search endpoint | Router: `/api/search` |
| `routes/datawindows.py` | DataWindow listing, control detail, lineage endpoints | Router: `/api/datawindows`, `/api/dw-controls` |
| `routes/tables.py` | Table inventory, lineage detail, DB stats | Router: `/api/tables`, `/api/stats` |
| `routes/queries.py` | Canned SQL query execution endpoints | Router: `/api/query` |
| `routes/diagrams.py` | SVG diagram generation endpoints | Router: `/api/diagrams` |
| `routes/static.py` | SPA index.html serving | Router: serves `index.html` for non-API paths |
| `services/objects.py` | Object business logic (detail, explore tree, source) | `get_object_detail`, `get_explore_tree`, `get_object_source`, `pbl_name` |
| `services/procedures.py` | Procedure business logic | `list_procedures`, `get_procedure_detail` |
| `services/search.py` | Search business logic | `search_objects`, `search_procedures` |
| `services/datawindows.py` | DataWindow business logic | `list_datawindows`, `get_dw_detail`, `get_dw_controls` |
| `services/tables.py` | Table business logic | `list_tables`, `get_table_detail`, `get_table_stats` |

### Top-level

| Module | Purpose | Key exports |
|---|---|---|
| `cli.py` | Thin Typer dispatch — wires commands to `shell/commands/` | `app`, `query_app` |

---

## How to add a new module

Follow this decision tree:

1. **Does it touch I/O?** → `shell/`
2. **Is it pure data/parsing?** → `core/`
3. **Is it a web endpoint?** → `explorer/routes/`
4. **Does it contain query business logic?** → `explorer/services/`
5. **Is it a CLI command implementation?** → `shell/commands/`

### Adding a new core module

1. Create `pb_cli/core/new_module.py`.
2. Start with `from __future__ import annotations` — never import `duckdb`,
   `subprocess`, `os`, `sys`, `pathlib.Path`, `graphviz`, or any framework.
3. Accept data via function arguments (dicts, NamedTuples, Text).
4. Return data via function arguments.
5. Write unit tests in `tests/test_new_module.py` with literal values — no
   fixtures, no DB, no subprocess.

### Adding a new shell module

1. Create `pb_cli/shell/new_module.py`.
2. Accept a `Conn` (DuckDB connection) for DB operations, or `Path` for
   filesystem operations — never open connections internally unless
   required by the function contract.
3. If orchestration code needs to call this module through `ShellEnv`,
   add a field to the appropriate sub-environment in `shell/env.py` and
   a corresponding `Protocol` (if keyword args/defaults matter) or
   `Callable` annotation.
4. Write tests using `RecordingReporter` and in-memory `ShellEnv` overrides.

### Adding a new explorer route

1. Create `pb_cli/explorer/routes/new_route.py` with an `APIRouter`.
2. Routes are thin: extract parameters, call a service function, return
   the result.
3. Business logic goes in `pb_cli/explorer/services/new_service.py`.
4. Register the router in `explorer/app.py` via `app.include_router(...)`.
5. Use `Depends(get_db)` for database access — the connection lifecycle is
   managed by the dependency.

### Adding a new CLI command

1. Create `pb_cli/shell/commands/new_cmd.py` with a `run(...)` function.
2. Add a `@app.command()` in `cli.py` that delegates to `shell.commands.new_cmd.run()`.
3. Use `env` for all side effects — never call `subprocess.run` or
   `duckdb.connect` directly from `cli.py`.

---

## What was gained

The refactoring (Plans 59–68) restructured `pb_cli/` from a flat module
layout into the layered architecture described above:

- **78 files changed**, +4,919 / −3,049 lines across the Python codebase.
- **290 pytest** (up from 174), ruff clean, pyright 0 errors.
- **Mockable boundaries** — every side effect flows through `ShellEnv`,
  enabling unit tests that don't touch the filesystem, database, or
  subprocesses.
- **Independently testable services** — business logic in
  `explorer/services/` is decoupled from FastAPI route wiring.
- **Clean layering** — `core/` is import-safe from any consumer; the
  dependency graph is strictly unidirectional.
