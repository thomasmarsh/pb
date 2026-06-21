# Plan 116 — Compiler Debt: Eliminate Python Analysis Duplication

## Charter

The Haskell pipeline (Passes 5–7) now produces type resolution, dataflow, and
taint analysis as JSON artifacts. But the Python CLI still re-derives much of
this from DuckDB at build time. This plan eliminates that duplication: remove
Python analysis code that the Haskell compiler already satisfies, and move the
remaining analysis to Haskell.

**Architectural constraint:** SQL parsing (`core/sql.py`) stays in Python.
The PB SQL dialect requires `sqlglot` for table/column extraction, and
decorating BsRaw SQL text is a CLI-layer concern, not a parser concern.

---

## Current state

### Haskell pipeline outputs (Passes 5–7)

| Artifact | Writer | Consumer |
|---|---|---|
| `resolved_types.json` | Pass 5 (`writeResolution`) | TS runtime (CpsCompile TypeEnv), Python `shell/type_resolution.py` → DuckDB |
| `resolved_calls.json` | Pass 5 | TS runtime, taint pass, Python `shell/type_resolution.py` → DuckDB |
| `global_vars.json` | Pass 5 | TS runtime, taint pass, Python `shell/type_resolution.py` → DuckDB |
| `proc_defs.json` | Pass 6 (`writeDataflowAnalysis`) | Taint pass |
| `proc_uses.json` | Pass 6 | Taint pass |
| `taint_sources.json` | Pass 7 (`writeTaintAnalysis`) | Python `shell/taint.py` → DuckDB |
| `taint_sinks.json` | Pass 7 | Python `shell/taint.py` → DuckDB |
| `taint_paths.json` | Pass 7 | Python `shell/taint.py` → DuckDB |
| `taint_annotations.json` | Pass 7 | Python `shell/taint.py` → DuckDB |
| `interproc_edges.json` | Pass 7 (`writeTaintAnalysis`) | Python `shell/interproc.py` → DuckDB |
| `procedure_summaries.json` | Pass 7 (`writeTaintAnalysis`) | Python `shell/interproc.py` → DuckDB |

### Python analysis modules that duplicate Haskell

| Module | Lines | What it does | Haskell equivalent | Verdict |
|---|---|---|---|---|
| `core/type_resolution.py` | 481 | Full type + call resolution | `TypeResolve` + `TypeEnv` (Pass 5) | **Kept** for unit/PBT tests; pipeline no longer calls it |
| `shell/type_resolution.py` | ~80 | JSON→DuckDB importer for Pass 5 output | N/A (import layer) | **Done** (CD-2) — rewritten as JSON importer |
| `core/interproc.py` | 311 | Inter-proc edge building | `Taint.buildInterprocEdges` (Pass 7) | **Pending** (Item 3) — `parse_params` moved inline |
| `shell/interproc.py` | 104 | I/O layer for interproc | Same | **Pending** (Item 3) — rewrite as JSON importer |
| `core/dead_code.py` | 146 | BFS reachability from entry points | `DeadCode` (Pass 8) | **Done** (CD-6) — ported to Haskell; Python module deleted |
| `shell/dead_code.py` | 42 | I/O layer for dead code | Same | **Remove** (after Haskell pass) |
| `core/ast_walker.py` | 154 | Re-walks AST JSON for calls/vars | `TypeResolve` extracts these | **Remove** (consumers use pre-computed facets) |
| `core/cfg_builder.py:build_cfg()` | ~278 | Python CFG construction | `CfgBuild` (Pass 3) | **Remove** (function dead; module stays for `cfg_from_json`) |
| `core/categorize.py` | 82 | BsRaw classification for debt reporting | No (by design — CLI diagnostic) | **Keep** |
| `core/sql.py` | 103 | PB SQL parsing via sqlglot | N/A (constraint) | **Keep** |
| `core/control_type.py` | — | Control type inference from naming convention | `TypeResolve.classifyControlType` (Pass 5) | **Deleted** (CD-2) — moved to Haskell |

### Haskell audit findings

| Priority | Item | Location | Status |
|---|---|---|---|
| P0 — Bug | DW `tab_seq` 0% measured: JSON key `tabSeq` vs script key `tab_seq` | `categorize.py:64` | **Done** (CD-0) |
| P1 — Test gap | `PB.Lexing.Escape` — zero test coverage for string chunk parsing | `parser/src/PB/Lexing/Escape.hs` | **Done** (CD-0, 22 tests) |
| P1 — Test gap | `PB.Pipeline.PbApi` — no tests for builtin name sets | `parser/src/PB/Pipeline/PbApi.hs` | **Done** (CD-0, 13 tests) |
| P2 — Dead code | `pbEscape` exported but never used | `Escape.hs:2` | **Done** (CD-0) |
| P2 — Dead code | `pEndKw`, `pProtoDecl` exported unnecessarily | `File.hs:10-11` | **Done** (CD-0) |
| P2 — Dead code | `walkFiles` exported unnecessarily | `Walk.hs:2` | **Done** (CD-0) |
| P3 — Feature | `try ... catch ... end try` not parsed (falls to BsRaw) | `Body.hs` — zero corpus occurrences | Pending |

---

## Work items

### Item 1 — Export interproc edges from Haskell (prerequisite for Items 2–3) ✅ DONE

**Problem:** `Taint.buildInterprocEdges` computes inter-proc edges internally
but `writeTaintAnalysis` doesn't write them to JSON. The Python `interproc.py`
re-derives the same edges from DuckDB.

**Fix (implemented CD-1):**
- Added `trEdges :: [InterprocEdge]` and `trProcedureSummaries :: [ProcedureSummary]` to `TaintResult`
- Added `buildProcedureSummaries` function to `Taint.hs`
- Added manual `ToJSON` instances for `InterprocEdge`, `ProcedureSummary`, `ProcSummaryReturnFlow` in `Serialise.hs` (matching Python snake_case keys)
- `writeTaintAnalysis` in `Runner.hs` now writes `interproc_edges.json` and `procedure_summaries.json`

**Files:** `Taint.hs`, `Runner.hs`, `Serialise.hs`

**Verification:** 0 corpus errors; JSON output has correct structure with snake_case keys matching DB schema.

---

### Item 2 — Remove `core/type_resolution.py` + `shell/type_resolution.py` ✅ DONE

**Problem:** `shell/type_resolution.py:build_type_tables()` re-runs the entire
type + call resolution pipeline from DuckDB, completely ignoring the
Haskell-produced `resolved_types.json` and `resolved_calls.json`. 650 lines
of Python duplicating Pass 5.

**Fix (implemented CD-2):**
1. Rewrote `shell/type_resolution.py` as ~80 line JSON→DuckDB importer
2. `build_type_tables` signature changed to `(conn, out_dir=None)` — reads
   `resolved_types.json`, `resolved_calls.json`, `global_vars.json` from `runner_out_dir`
3. Updated `shell/env.py` and `shell/pipeline.py` to pass `runner_out_dir`
4. **Control type inference moved to Haskell** — `classifyControlType` added
   to `TypeResolve.hs`, called from `resolveTypes` as fallback when type is
   `unresolved`. `resolved_types.json` now includes control-inferred types.
5. Deleted `core/control_type.py` (was Python-only; now in Haskell)
6. `parse_params` moved inline into `core/interproc.py` (only remaining consumer)
7. **`core/type_resolution.py` kept** — 66 unit/PBT tests import from it;
   pipeline no longer calls these functions

**Decisions:**
- Control type inference (`classifyControlType`) lives in Haskell `TypeResolve`
  because it's a pure type classifier that fits naturally alongside
  `classifyPbType`. This means `resolved_types.json` already includes
  naming-convention inferred types, so no Python post-processing needed.
- `core/type_resolution.py` retained for test coverage — its pure functions
  (`parse_params`, `classify_type`, `resolve_types`, `resolve_calls`) are
  still imported by `test_type_resolution.py` (51 tests) and
  `test_type_resolution_pbt.py` (15 tests). These test the Python
  implementation's correctness as regression tests.

**Files:** `shell/type_resolution.py`, `shell/env.py`, `shell/pipeline.py`, `core/interproc.py`, `TypeResolve.hs`, `core/control_type.py` (deleted)

**Verification:** 577 Python tests pass; `build_type_tables(conn, None)` clears tables (backward-compatible for tests that call without out_dir).

---

### Item 3 — Remove `core/interproc.py` + `shell/interproc.py` ✅ DONE

**Problem:** `interproc.py` builds inter-proc edges from DuckDB. The Haskell
`taintAnalysis` already builds identical edges via `buildInterprocEdges`.
After Item 1 exports these to JSON, the Python re-derivation is redundant.

**Note (CD-2):** `parse_params` was moved inline into `core/interproc.py`
(it was the only remaining import from `core/type_resolution.py`).

**Fix (implemented CD-3):**
1. **Prerequisite fix:** `Taint.ResolvedCallRow`'s `FromJSON` had wrong key
   names — expected snake_case (`from_proc`, `resolution_kind`) but
   `TypeResolve.ResolvedCall` serializes as camelCase (`fromProc`, `kind`).
   `loadJsonArray` silently returned `[]` → zero interproc edges. Fixed
   keys to match actual JSON output. `interproc_edges.json`: 0 → 305,674
   records.
2. Rewrote `shell/interproc.py` as ~63 line JSON→DuckDB importer
   (reads `interproc_edges.json` + `procedure_summaries.json`).
3. `build_interproc_tables` signature changed to `(conn, out_dir=None)`
4. Updated `shell/env.py` field type and `shell/pipeline.py` caller
5. **`core/interproc.py` kept** — 28 unit tests import from it;
   pipeline no longer calls `build_interproc_flow`

**Files:** `shell/interproc.py`, `shell/env.py`, `shell/pipeline.py`,
`tests/test_shell_pipeline.py`, `parser/src/PB/Pipeline/Taint.hs`

---

### Item 4 — Move dead code analysis to Haskell ✅ DONE

**Problem:** `core/dead_code.py` (146 lines) does BFS reachability from entry
points through the call graph. This is a core static analysis feature that
belongs in the parser pipeline, not the CLI.

**Fix (implemented CD-6):**
1. **New Haskell module `PB.Pipeline.DeadCode`** (162 lines) — BFS from
   entry points through same-object, cross-object, and override edges.
   Includes `cyclomaticComplexity` (E - N + 2) and `computeDeadProcedures`.
2. **Pass 8 in `Runner.hs`** — `writeDeadCodeAnalysis` produces
   `dead_procedures.json` with snake_case keys via manual `ToJSON` instance.
3. **`shell/dead_code.py` rewritten as JSON→DuckDB importer** — reads
   `dead_procedures.json`, bulk-inserts. Signature changed to
   `(conn, out_dir: Path | None)` matching taint/interproc pattern.
4. **`core/dead_code.py` deleted** — no Python tests imported from it
   (unlike `core/type_resolution.py` and `core/interproc.py` which are
   retained for their unit tests). Algorithm correctness tested in Haskell
   `DeadCodeTest.hs` (17 tests).
5. **`env.py` updated** — `build_dead_code_table` type changed to
   `Callable[[Conn, Path | None], None]`.
6. **`pipeline.py` updated** — passes `runner_out_dir`.
7. **Tests updated** — `test_analysis_routes.py` fixture writes synthetic
   JSON; `conftest.py` and `test_shell_pipeline.py` updated for new signature.

**Files:** New `PB.Pipeline.DeadCode`, `DeadCodeTest.hs`, `Runner.hs`,
`Serialise.hs`, `pb-ast.cabal`, `Main.hs`; `shell/dead_code.py` (rewrite),
`shell/env.py`, `shell/pipeline.py`, `test_analysis_routes.py`,
`test_shell_pipeline.py`, `conftest.py`; `core/dead_code.py` (deleted)

**Verification:** 1086 Haskell (+17), 555 pytest (0 ruff, 0 pyright),
0 corpus errors (1069 files).

---

### Item 5 — Remove redundant `ast_walker.py` functions ✅ DONE

**Problem:** `walk_calls()`, `walk_local_vars()`, `count_branches()` in
`ast_walker.py` re-extract information from raw AST JSON that `TypeResolve`
already produces as pre-computed facets.

**Fix (implemented CD-4):**
1. **`count_branches` removed from `importing.py`** — replaced with
   `_cfg_cyclomatic()` which computes cyclomatic complexity from the
   Haskell-produced CFG (`cfg_json`): `E - N + 2*P` (connected components).
2. **`walk_local_vars` removed from `importing.py`** — `local_variables`
   table now populated from `resolved_types.json` via `build_call_tables`.
3. **`walk_calls` kept in `importing.py` and `ast_walker.py`** — still needed
   by the streaming import path (`run_from_jsonl_lines`, used by test fixture)
   and DW control call extraction (`_import_dw`). The production pipeline's
   `build_call_tables` overwrites the `calls` table with `resolved_calls.json`
   data after import.
4. **`count_branches` and `walk_local_vars` removed from `ast_walker.py`**
5. Added `build_call_tables(conn, out_dir)` to `shell/type_resolution.py` —
   populates `calls` and `local_variables` from resolved JSON.
6. Updated `_proc_row` to use `_cfg_cyclomatic(block.get("cfg"))` instead
   of `count_branches(body) + 1`.
7. Removed `count_branches`/`walk_local_vars` tests from `test_core_ast_walker.py`
   and `test_shell_metrics.py`. Updated cyclomatic tests in `test_index.py`
   to provide `cfg` dicts matching expected complexity.

**Files:** `core/ast_walker.py`, `core/importing.py`, `shell/type_resolution.py`,
`shell/env.py`, `shell/pipeline.py`, `tests/test_core_ast_walker.py`,
`tests/test_shell_metrics.py`, `tests/test_shell_pipeline.py`,
`tests/test_index.py`

**Verification:** 1069 Haskell, 566 pytest, 0 pyright, 0 ruff, 0 corpus errors (1067 files).

**Note:** `walk_calls` was supposed to be fully removed per the original plan,
but the streaming test path (`run_from_jsonl_lines`) and DW control call
extraction still need it. The production pipeline overwrites `calls` via
`build_call_tables(conn, runner_out_dir)`. A future session can migrate the
test fixture to use file mode (`-o` instead of `--jsonl`) and then fully
remove `walk_calls`.

---

### Item 6 — Remove dead Python CFG builder function ✅ DONE

**Problem:** `cfg_builder.py:build_cfg()` (the Python CFG construction, ~278
lines) is never called from the pipeline. The Haskell `CfgBuild` produces CFGs.
The module stays because `cfg_from_json()` and `mark_unreachable()` are used
by `cfg_renderer.py`.

**Fix (implemented CD-5):**
1. Deleted `build_cfg()` and all its helpers: `_Counter`, `_flush_block`,
   `_new_block`, `_add_edge`, `_lower`, `_lower_if`, `_lower_for`,
   `_lower_do`, `_lower_choose` (~240 lines removed)
2. Updated `diagrams.py` — removed `build_cfg` import, returns `None` when
   `cfg_json_raw` is absent (Haskell pipeline always produces it)
3. Rewrote `test_cfg_builder.py` — removed all `build_cfg`-dependent tests,
   remaining tests construct `CFG` objects directly
4. Module reduced from 399 → 148 lines

**Files:** `core/cfg_builder.py`, `explorer/services/diagrams.py`, `tests/test_cfg_builder.py`

**Verification:** 15 pytest pass, 0 ruff, 0 pyright, 0 corpus errors (1067 files).

---

### Item 7 — Fix DW `tab_seq` measurement bug ✅ DONE

**Problem:** `categorize.py:64` looks for key `tab_seq` in DW control JSON,
but the Haskell serializer produces `tabSeq` (via `stripCamelCasePrefix`).
Result: 0% measured coverage despite the field being parsed correctly.

**Fix (implemented CD-0):** Updated `categorize.py:64` to use `tabSeq`.
Also fixed `importing.py:256` which had the same bug.

**Files:** `cli/pb_cli/core/categorize.py`, `cli/pb_cli/core/importing.py`

---

### Item 8 — Add `PB.Lexing.Escape` tests ✅ DONE

**Problem:** Zero test coverage for string chunk parsing. The lexer uses
`pbStringChunk`, `pbDwStringChunk`, `pbSelectTildeStr` for handling
escape sequences in PB strings. These are critical for correct tokenization.

**Fix (implemented CD-0):** New `parser/test/EscapeTest.hs` with 22 tests:
- `pbStringChunk`: single char, multiple chars, tilde escapes (`~n`, `~t`, `~~`),
  `~o`/`~h` multi-char escapes, delimiter stops, newline rejection, empty input
- `pbDwStringChunk`: single char, allows newline, tilde escapes, empty input
- `pbSelectTildeStr`: simple content, empty content, `~~` (literal tilde),
  `~~"` (escaped tilde-quote), embedded `~~`

**Files:** `parser/test/EscapeTest.hs`, `parser/test/Main.hs`, `parser/pb-ast.cabal`

---

### Item 9 — Add `PB.Pipeline.PbApi` tests ✅ DONE

**Problem:** `builtinFnNames` and `builtinMethodNames` are static sets used
by `TypeResolve` for call classification. If these sets are wrong, calls are
silently misclassified. No tests verify their contents.

**Fix (implemented CD-0):** New `parser/test/PbApiTest.hs` with 13 tests:
- `builtinFnNames` is non-empty
- `builtinMethodNames` is non-empty
- Fn and method sets are disjoint
- `builtinFnNames` contains `len`, `trim`, `mid`, `left`, `right`, `string`
- `builtinMethodNames` contains `retrieve`, `update`, `insertrow`, `deleterow`, `reset`

**Files:** `parser/test/PbApiTest.hs`, `parser/test/Main.hs`, `parser/pb-ast.cabal`

---

### Item 10 — Remove dead exports from Haskell modules ✅ DONE

**Problem:** Several functions are exported but never imported:
- `pbEscape` in `Escape.hs` — never used anywhere
- `pEndKw`, `pProtoDecl` in `File.hs` — only used internally
- `walkFiles` in `Walk.hs` — only used internally

**Fix (implemented CD-0):** Removed from export lists:
- `pbEscape` removed from `Escape.hs` export list (function kept for internal use)
- `pEndKw`, `pProtoDecl` removed from `File.hs` export list
- `walkFiles` removed from `Walk.hs` export list

**Files:** `Escape.hs`, `File.hs`, `Walk.hs`

---

## Ordering

### Completed sessions

1. **CD-0** — Items 7, 10, 8, 9 (tab_seq fix, dead exports, Escape + PbApi tests)
2. **CD-1** — Item 1 (export interproc edges + procedure summaries)
3. **CD-2** — Item 2 (JSON importer for type resolution + control inference in Haskell)
4. **CD-3** — Item 3 (JSON importer for interproc + fixed ResolvedCallRow FromJSON)
5. **CD-4** — Item 5 (CFG-based cyclomatic + resolved JSON for local_variables; walk_calls kept for streaming path)
6. **CD-5** — Item 6 (remove dead CFG builder function)
7. **CD-6** — Item 4 (move dead_code to Haskell; delete core/dead_code.py)

### Remaining work

**None** — all items complete. Plan 116 is finished.

---

## Success criteria

1. ~~`core/type_resolution.py` deleted~~ → **Kept** for unit/PBT tests; pipeline
   no longer calls it. `shell/type_resolution.py` is a thin JSON→DuckDB importer.
2. `core/interproc.py` deleted; `shell/interproc.py` is a thin importer **✅ Done (CD-3)**
3. `core/dead_code.py` deleted; Haskell `PB.Pipeline.DeadCode` produces
   `dead_procedures.json` **✅ Done (CD-6)**
4. `core/ast_walker.py` has `walk_calls` and `walk_local_vars` removed **✅ Done (CD-4): walk_local_vars removed; walk_calls kept for streaming path**
5. `cfg_builder.py:build_cfg()` function deleted **✅ Done (CD-5)**
6. `categorize.py` correctly measures `tabSeq` coverage **✅ Done (CD-0)**
7. `EscapeTest.hs` and `PbApiTest.hs` exist with > 10 tests each **✅ Done (CD-0)**
8. Dead exports removed from `Escape.hs`, `File.hs`, `Walk.hs` **✅ Done (CD-0)**
9. `cabal test` + `pnpm test` + `uv run pytest` all pass **✅ All pass**
10. `./pb check-corpus` — 0 errors **✅ 0 errors / 1067 files**
11. `interproc_edges.json` and `procedure_summaries.json` exported from Pass 7 **✅ Done (CD-1); interproc_edges was 0 due to FromJSON key mismatch, fixed in CD-3 (now 305,674)**
12. `build_type_tables` reads from Haskell JSON, not DuckDB re-derivation **✅ Done (CD-2)**
13. Control type inference lives in Haskell `TypeResolve.classifyControlType` **✅ Done (CD-2)**

---

## Out of scope

- **SQL parsing** — stays in Python (`core/sql.py`). Architectural constraint:
  PB SQL dialect requires `sqlglot` for table/column extraction.
- **`core/slicing.py`** — legitimately CLI (interactive query-time analysis).
- **`core/cfg_renderer.py`**, **`core/diagram_builder.py`** — visualization,
  legitimately CLI.
- **`core/importing.py`** — JSON→DuckDB bridge, legitimately CLI.
- **`try ... catch ... end try`** — zero corpus occurrences; implement when
  real examples surface (dormant per BACKLOG).
- **`core/categorize.py`** — diagnostic reporting tool, legitimately CLI.

---

## Session log

### CD-0 (Items 7, 10, 8, 9)

**Decisions:**
- `tab_seq` fix applied to both `categorize.py:64` and `importing.py:256` (same
  root cause: Haskell serializer produces `tabSeq` via `stripCamelCasePrefix`)
- `pbEscape` removed from export list but kept internally (used by `pbStringChunk`
  and `pbDwStringChunk`)
- Escape tests: `pbEscape` preserves escape text (doesn't interpret); interpretation
  happens at the lexer level. Tests verify raw text preservation.

### CD-1 (Item 1)

**Decisions:**
- Added `ProcedureSummary` and `ProcSummaryReturnFlow` types to `Taint.hs`
  (not just edges — Python `interproc.py` builds summaries too)
- Manual `ToJSON` instances (not `genericToJSON`) because Python consumers
  expect snake_case keys (`caller_object`, `callee_proc`, etc.)
- Edges and summaries threaded through `TaintResult` (not computed separately)
  since `taintAnalysis` already computes them internally

### CD-2 (Item 2)

**Decisions:**
- **Control type inference moved to Haskell** (`TypeResolve.classifyControlType`)
  rather than staying as Python post-processing. Rationale: it's a pure type
  classifier that fits naturally alongside `classifyPbType`; `resolved_types.json`
  now includes control-inferred types so no Python post-processing needed;
  TS runtime benefits too.
- **`core/type_resolution.py` kept** (not deleted) because 66 unit/PBT tests
  import from it. The pipeline no longer calls these functions, but the tests
  validate the Python implementation's correctness as regression tests.
  If these tests become a maintenance burden, they can be ported to test the
  Haskell output via JSON comparison in a future session.
- `parse_params` moved inline into `core/interproc.py` (only remaining consumer
  before Item 3 deletes that module).
- `build_type_tables` signature changed to `(conn, out_dir=None)` — backward-
  compatible for tests that call without `out_dir` (clears tables).

**Learnings:**
- `cabal clean` needed when the build cache has stale errors (GHC error state
  persisted across builds, causing misleading errors in downstream tools)
- `where` blocks in Haskell don't capture `let` bindings — `lower` must be
  defined in the `where` block alongside `go`, not in a `let` above

### CD-3 (Item 3)

**Decisions:**
- **Prerequisite bug found and fixed:** `Taint.ResolvedCallRow` `FromJSON`
  expected snake_case keys but `TypeResolve.ResolvedCall` serializes camelCase.
  This caused `loadJsonArray` to silently fail, producing 0 interproc edges.
  Fixed the `FromJSON` instance to match actual JSON output.
- **`core/interproc.py` kept** (not deleted) because 28 unit tests import
  `GlobalDataFlow`, `InterProcEdge`, `build_interproc_flow`, `match_args_to_params`
  from it. Same pattern as `core/type_resolution.py` in CD-2.
- `shell/interproc.py` rewritten as ~63 line JSON importer matching the
  `shell/taint.py` pattern. JSON keys from Haskell match DB schema exactly
  (both use snake_case via manual `ToJSON` instances in Serialise.hs).

**Metrics:**
- `interproc_edges.json`: 0 → 305,674 records (after FromJSON fix)
- `procedure_summaries.json`: 2,649 records (unchanged)
- 1069 Haskell, 577 pytest, 0 pyright, 0 ruff, 0 corpus errors (1067 files)

### CD-4 (Item 5)

**Decisions:**
- **`count_branches` replaced with CFG-based computation** — `_cfg_cyclomatic()`
  computes `E - N + 2*P` from the Haskell-produced CFG. Handles disconnected
  components (unreachable blocks) via BFS connected-component counting.
- **`walk_local_vars` replaced by `resolved_types.json`** — new
  `build_call_tables(conn, out_dir)` function in `shell/type_resolution.py`
  populates `local_variables` from `resolved_types.json` (non-parameter entries).
- **`walk_calls` kept** (not fully removed) — the streaming import path
  (`run_from_jsonl_lines`, used by test fixture) and DW control call extraction
  (`_import_dw`) still need it. The production pipeline's `build_call_tables`
  overwrites the `calls` table with `resolved_calls.json` data.
- **`build_call_tables` wired into pipeline** — called after `build_type_tables`,
  populates `calls` from `resolved_calls.json` and `local_variables` from
  `resolved_types.json`.

**Metrics:**
- 1069 Haskell, 566 pytest (+1 net: new test_shell_pipeline mock), 0 pyright, 0 ruff
- 0 corpus errors (1067 files)

### CD-5 (Item 6)

**Decisions:**
- **Pure deletion** — removed `build_cfg()` and all 9 helper functions (~240
  lines). Module reduced from 399 to 148 lines.
- **`diagrams.py` fallback** — when `cfg_json_raw` is None (no Haskell CFG),
  the diagram endpoint now returns None rather than attempting a Python CFG
  build. In production the Haskell pipeline always produces `cfg_json`.
- **Tests rewritten** — removed all 20 `build_cfg`-dependent tests (TestLinearBody,
  TestBsIf, TestBsFor, TestBsDo, TestBsChoose, TestTerminals, TestNesting).
  Remaining 15 tests construct `CFG` objects directly via `_cfg()` helper.

**Metrics:**
- 1069 Haskell, 566 pytest, 0 pyright, 0 ruff
- 0 corpus errors (1067 files)

### CD-6 (Item 4)

**Decisions:**
- **Pass 8 (not folded into Pass 7)** — dead code is a distinct analysis step
  with its own JSON artifact, cleanly separable from taint.
- **`core/dead_code.py` deleted** — unlike `core/type_resolution.py` (66
  tests) and `core/interproc.py` (28 tests), the dead code module had zero
  Python tests. Algorithm correctness is fully covered by Haskell
  `DeadCodeTest.hs` (17 tests).
- **`test_analysis_routes.py` fixture rewritten** — instead of setting up
  synthetic DB tables and calling the old `build_dead_code_table(conn)`, the
  fixture now writes a `dead_procedures.json` (matching Haskell output) and
  calls `build_dead_code_table(conn, out_dir)`. Tests verify the API endpoint
  reads the JSON correctly.
- **DW object detection** — uses `.srd` file extension (DataWindow SR files),
  matching the Haskell convention.

**Metrics:**
- 1086 Haskell (+17 DeadCodeTest), 555 pytest, 0 pyright, 0 ruff
- 0 corpus errors (1069 files)
