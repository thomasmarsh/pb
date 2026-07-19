# CLI / Python Backend — Subsystem Guide

Loaded automatically by Claude Code whenever a session reads or edits files
under `cli/`. This file covers Python-specific rules only — session
protocol, the staged verification loop, commit discipline, documentation
style, and change-scope rules live in the root `CLAUDE.md` and apply here too.

## Verification

```text
cd cli && uv run pytest lib/tests/ pipeline/tests/ api/tests/  # tests
cd cli && uv run ruff check     # lint
cd cli && uv run pyright        # type check (0 errors baseline)
```

## Backend SQL mock mode

Set `PB_SQL_MOCK=1` to return canned data instead of connecting
to MySQL. Useful for development iteration without a running database:

```bash
PB_SQL_MOCK=1 cd cli && uv run pb explore   # mock mode
uv run pb explore                            # live mode (default)
```

## SQL worker bridge

`cli/pipeline/src/pb/pipeline/bridge/sql_worker.py` is the sqlglot bridge the
Haskell compiler shells out to for SQL/DDL parsing (`PB.Pipeline.SqlParse`
in `compiler/CLAUDE.md`). It is invoked as `<python> -m
pb.pipeline.bridge.sql_worker`, never via an installed console-script shim —
if you touch its location or entry point, update
`PB.Pipeline.SqlParse.sqlWorkerModuleArgs` on the Haskell side in the same
change.
