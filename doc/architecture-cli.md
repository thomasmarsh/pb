# CLI Architecture

This document describes the three-package architecture of the Python workspace,
the dependency rules that keep it testable, and how to add new modules without
violating the invariants.

---

## Overview

The Python layer is organised into three packages in a uv workspace, each with
a single responsibility:

```
┌─────────────────────────────────────────────────────┐
│  pb.api       — FastAPI web layer                    │
│  routes thin → services contain logic                │
├─────────────────────────────────────────────────────┤
│  pb.pipeline  — CLI tool + orchestration             │
│  compiler invocation, DB, display, subprocess        │
├─────────────────────────────────────────────────────┤
│  pb.lib       — Pure data transforms                 │
│  parsers, walkers, models, SQL pre-processing        │
└─────────────────────────────────────────────────────┘
```

**`pb.lib`** holds everything that can be unit-tested with literal Python
values — no I/O, no network, no subprocess calls, no framework imports.
This is the functional core.

**`pb.pipeline`** is the imperative boundary. It owns all side-effecting
operations: filesystem reads, `pbc` subprocess invocation, DuckDB
connections, and rich console output. Every side effect flows through
`ShellEnv` closures, making them swappable in tests.

**`pb.api`** is a thin FastAPI web layer. Routes extract parameters and
delegate to services. Services contain the business logic. Both import
from `pb.lib` for pure data and from `pb.pipeline` for database access.

**`pb.pipeline.cli`** is a thin Typer dispatch that wires commands to
`pb.pipeline.commands/` implementations.

---

## Dependency rules

The import graph is strictly layered:

| Import direction | Allowed? | Example |
|---|---|---|
| `pb.lib` → `pb.pipeline` | **No** | Never |
| `pb.lib` → `pb.api` | **No** | Never |
| `pb.pipeline` → `pb.lib` | **Yes** | `pb.pipeline.env` imports `pb.lib.models` |
| `pb.api` → `pb.lib` | **Yes** | `pb.api.services` imports `pb.lib.slicing` |
| `pb.api` → `pb.pipeline` | **Yes** | `pb.api.routes.diagrams` imports `pb.pipeline.diagrams` |
| `pb.pipeline.cli` → `pb.pipeline` | **Yes** | `pb.pipeline.cli` imports `pb.pipeline.env`, `pb.pipeline.commands/` |
| `pb.pipeline.cli` → `pb.api` | **Yes** | Only `from pb.api import create_app` |

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
Parsing via the `pbc` Haskell binary and rich error rendering.
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
from pb.pipeline.env import ShellEnv

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

### `pb.lib` — Pure transforms (zero I/O)

| Module | Purpose | Key exports |
|---|---|---|
| `models.py` | Row types (`NamedTuple`) and `RowBatch` container | `ObjectRow`, `ProcedureRow`, `CallRow`, `DwControlRow`, `SqlStatementRow`, `InheritsRow`, `RowBatch`, `new_row_batch`, `TABLES` |
| `sql.py` | PowerBuilder SQL parser (wraps sqlglot with PB-specific rewrites) | `parse_pb_sql` |
| `state.py` | Pure file-state diffing | `FileDiff`, `diff_state` |
| `cfg_builder.py` | CFG reconstruction from JSON | `cfg_from_json`, `compute_node_states` |
| `cfg_renderer.py` | CFG → GraphViz DOT | `cfg_to_dot` |
| `diagram_builder.py` | Pure diagram styling and GraphViz render functions | `render_calls`, `render_dw_tables`, `render_heatmap`, `render_inheritance`, `render_proc_tables`, `render_sql_lineage`, `render_table_lineage`, `KIND_COLORS`, `GRAPH_ATTRS` |
| `slicing.py` | Backward/forward program slicing | `backward_slice`, `forward_slice`, `build_proc_def_use` |

### `pb.pipeline` — Imperative boundary (I/O-bound)

| Module | Purpose | Key exports |
|---|---|---|
| `env.py` | `ShellEnv` composition pattern (BuildEnv / RunnerEnv / StorageEnv) | `ShellEnv`, `env`, `BuildEnv`, `RunnerEnv`, `StorageEnv` |
| `build.py` | Repo discovery, `pbc` binary build, file enumeration | `find_repo`, `build_runner`, `find_binary`, `walk_sr_files`, `count_sr_files`, `hash_source_dir`, `ensure_explorer_built`, `build_subset_tmpdir`, `get_queries_dir` |
| `runner.py` | Error rendering helpers | `render_error` |
| `db.py` | DuckDB connection management, query parsing | `db_connection`, `setup_db_extras`, `Conn`, `parse_sql_file` |
| `db_batch.py` | Bulk insert helper | `bulk_insert` |
| `metrics.py` | Graph metric computation (PageRank, betweenness, DIT) | `compute_metrics`, `compute_dit` |
| `diagrams.py` | DOT/SVG diagram building, LRU-cached rendering | `render_svg` |
| `pipeline.py` | `pb index` orchestration | `run`, `db_is_current` |
| `pbl.py` | PBL binary library extraction | `extract`, `extract_to_dir`, `resolve_source_dir` |
| `reporter.py` | Unified output protocol for pipeline operations | `Reporter`, `LiveReporter`, `RecordingReporter` |
| `queries.py` | Auto-register `queries/*.sql` files as `pb query <name>` commands | `register_queries` |
| `impact.py` | Impact analysis command | `run_impact` |
| `commands/corpus.py` | `pb check-corpus` implementation | `run` |
| `commands/clean.py` | `pb clean` implementation | `run` |
| `commands/bombadil.py` | Dev subcommands | `app` |
| `bridge/sql_worker.py` | SQL bridge subprocess worker (stdin/stdout jsonl) | `main` |

### `pb.api` — FastAPI web layer

| Module | Purpose | Key exports |
|---|---|---|
| `app.py` | FastAPI application factory, router registration, SPA fallback | `create_app` |
| `routes/dependencies.py` | Shared DB connection dependency and `rows()` helper | `get_db`, `get_conn`, `rows` |
| `routes/objects.py` | Object listing, detail, source, explore tree endpoints | Router: `/api/objects` |
| `routes/procedures.py` | Procedure listing and detail endpoints | Router: `/api/procedures` |
| `routes/search.py` | Full-text search endpoint | Router: `/api/search` |
| `routes/datawindows.py` | DataWindow listing, control detail, lineage endpoints | Router: `/api/datawindows` |
| `routes/tables.py` | Table inventory, lineage detail, DB stats | Router: `/api/tables` |
| `routes/queries.py` | Canned SQL query execution endpoints | Router: `/api/query` |
| `routes/diagrams.py` | SVG diagram generation endpoints | Router: `/api/diagrams` |
| `routes/static.py` | SPA index.html serving | Router: serves `index.html` for non-API paths |
| `services/datawindows.py` | DataWindow business logic | `list_datawindows`, `get_dw_detail`, `get_dw_controls` |
| `services/tables.py` | Table business logic | `list_tables`, `get_table_detail`, `get_table_stats` |

### Top-level

| Module | Purpose | Key exports |
|---|---|---|
| `cli.py` | Thin Typer dispatch — wires commands to `commands/` | `app`, `query_app` |

---

## How to add a new module

Follow this decision tree:

1. **Does it touch I/O?** → `pb.pipeline`
2. **Is it pure data/parsing?** → `pb.lib`
3. **Is it a web endpoint?** → `pb.api.routes/`
4. **Does it contain query business logic?** → `pb.api.services/`
5. **Is it a CLI command implementation?** → `pb.pipeline.commands/`

### Adding a new lib module

1. Create `cli/lib/src/pb/lib/new_module.py`.
2. Start with `from __future__ import annotations` — never import `duckdb`,
   `subprocess`, `os`, `sys`, `pathlib.Path`, `graphviz`, or any framework.
3. Accept data via function arguments (dicts, NamedTuples, Text).
4. Return data via function arguments.
5. Write unit tests in `cli/lib/tests/test_new_module.py` with literal values — no
   fixtures, no DB, no subprocess.

### Adding a new pipeline module

1. Create `cli/pipeline/src/pb/pipeline/new_module.py`.
2. Accept a `Conn` (DuckDB connection) for DB operations, or `Path` for
   filesystem operations — never open connections internally unless
   required by the function contract.
3. If orchestration code needs to call this module through `ShellEnv`,
   add a field to the appropriate sub-environment in `pipeline/env.py` and
   a corresponding `Protocol` (if keyword args/defaults matter) or
   `Callable` annotation.
4. Write tests using `RecordingReporter` and in-memory `ShellEnv` overrides.

### Adding a new API route

1. Create `cli/api/src/pb/api/routes/new_route.py` with an `APIRouter`.
2. Routes are thin: extract parameters, call a service function, return
   the result.
3. Business logic goes in `cli/api/src/pb/api/services/new_service.py`.
4. Register the router in `api/app.py` via `app.include_router(...)`.
5. Use `Depends(get_db)` for database access — the connection lifecycle is
   managed by the dependency.

### Adding a new CLI command

1. Create `cli/pipeline/src/pb/pipeline/commands/new_cmd.py` with a `run(...)` function.
2. Add a `@app.command()` in `pipeline/cli.py` that delegates to `pipeline.commands.new_cmd.run()`.
3. Use `env` for all side effects — never call `subprocess.run` or
   `duckdb.connect` directly from `cli.py`.

---

## What was gained

The refactoring (Plans 59–68) structured the Python layer into three packages:

- **pb.lib** — pure transforms, zero I/O, independently testable
- **pb.pipeline** — CLI tool + orchestration, mockable via `ShellEnv`
- **pb.api** — FastAPI web layer, thin routes + service business logic
- **339 tests**, ruff clean, pyright 0 errors.
- **Mockable boundaries** — every side effect flows through `ShellEnv`,
  enabling unit tests that don't touch the filesystem, database, or
  subprocesses.
- **Independently testable services** — business logic in
  `pb.api.services/` is decoupled from FastAPI route wiring.
- **Clean layering** — `pb.lib` is import-safe from any consumer; the
  dependency graph is strictly unidirectional.
