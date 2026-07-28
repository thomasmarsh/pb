# CLI / Python Backend — Subsystem Guide

Loaded automatically by Claude Code whenever a session reads or edits files
under `cli/`. This file covers Python-specific rules only — session
protocol, the staged verification loop, commit discipline, documentation
style, and change-scope rules live in the root `AGENTS.md` and apply here too.

## Backend SQL mock mode

`PB_SQL_MOCK=1` returns canned data instead of connecting to MySQL — useful
for development iteration without a running database. See root `AGENTS.md`
Quick Reference for the invocation.

## SQL worker bridge

`cli/pipeline/src/pb/pipeline/bridge/sql_worker.py` is the sqlglot bridge the
Haskell compiler shells out to for SQL/DDL parsing (`PB.Pipeline.SqlParse`
in `compiler/AGENTS.md`). It is invoked as `<python> -m
pb.pipeline.bridge.sql_worker`, never via an installed console-script shim —
if you touch its location or entry point, update
`PB.Pipeline.SqlParse.sqlWorkerModuleArgs` on the Haskell side in the same
change.

## Renaming or adding a DuckDB column

`pb.duckdb`'s schema is owned by `compiler/src/PB/Pipeline/DuckDb.hs`, not
`cli/` — but a rename ripples into `cli/`'s row builders, pydantic models,
and hand-written SQL strings every time. Before touching a column name a
`cli/`-only session references, read `compiler/AGENTS.md`'s "DuckDB Schema
Standards" section first: it has the naming conventions, the full
five-layer consumer checklist, and the pointer to `doc/architecture-
pipeline.md`'s §5 schema listing (read that, not `initSchema`, for schema
shape lookups when you are not the one changing it).
