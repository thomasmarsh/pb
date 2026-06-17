# Development Guide

## Build overview

| Component      | Command                    | What it does                        |
| -------------- | -------------------------- | ----------------------------------- |
| Haskell parser | `cd parser && cabal build` | Compile library + executables       |
| Haskell tests  | `cd parser && cabal test`  | Run 818 property + unit tests       |
| Python tools   | `./pb index`               | Parse → import → analyze pipeline   |
| Python tests   | `cd cli && uv run pytest`  | 349 tests across tooling            |
| Explorer TS    | `pnpm build` (in `ui/`)    | Bundle TS → JS for the web UI       |
| Explorer tests | `pnpm test` (in `ui/`)     | 253 reducer + state management tests |
| Corpus check   | `./pb check-corpus`        | 0 errors / 777 files baseline       |

CI runs all of these on every push to `main`.

---

## Parser coverage check

```bash
./pb check-corpus   # 0 errors / 777 files = baseline
```

---

## Debt analysis

Measure how much of the AST is still in raw fallback form (unclassified
statements and expressions). Useful for tracking parser coverage.

```bash
./pb debt --no-build   # skips cabal build if pb-runner is already fresh
```

---

## Adding queries

Drop a `.sql` file into `queries/` and it becomes a `pb query` command automatically.
The leading comment block sets the description and parameters:

```sql
-- One-line description shown in pb --help.
-- :name TEXT          ← required positional argument
-- :n INT 20           ← optional --n flag with default 20
SELECT ...
WHERE col = $name
LIMIT $n;
```

---

## Further reading

- **[`architecture.md`](architecture.md)** — component map, data flow, cross-component
  interfaces, testing, and build sequence.
- **[`architecture-cli.md`](architecture-cli.md)** — CLI module reference.
- **[`vision.md`](vision.md)** — architectural rationale, LLM integration workflow,
  DuckDB schema design, and the full operational pipeline.
- **[`spec.md`](spec.md)** — parser specification: lexical rules, token forms,
  file structure, DataWindow syntax.
- **`CLAUDE.md`** — development protocol: staged verification loop, corpus
  gates, module placement guide, and code index.
