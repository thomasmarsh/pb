# PB Compiler (Haskell) — Subsystem Guide

Loaded automatically by Claude Code whenever a session reads or edits files under
`compiler/`. This file covers Haskell/parser-specific rules only — session
protocol, the staged verification loop, commit discipline, documentation
style, and change-scope rules live in the root `CLAUDE.md` and apply here too.

## Stage 0 — Compiler-Specific Diagnostics

**Diagnosing corpus failures.** When the charter is to reduce corpus errors, sample raw error messages before touching code:

```bash
./pb check-corpus 2>&1 | grep "Files processed"   # get count

# sample 5 error messages from a temporary run:
OUT=$(mktemp -d)
(cd compiler && cabal run pbc -v0 -- -i ../example/openpay-0.1.1b-extract -o "$OUT" 2>/dev/null)
python3 -c "
import json, os, glob
for f in list(glob.glob('$OUT/**/*.json', recursive=True))[:5]:
    d = json.load(open(f))
    if 'error' in d: print(d['error'][:200])
"
rm -rf "$OUT"
```

Map the error message to its layer before reading code:

- `"lex error at line N"` → look at physical line N in the source file; the issue is in `Lexer.hs` or `Preprocess.hs`
- Megaparsec grammar message → issue is in `Grammar/File.hs` or `Grammar/Stream.hs`

**JSON body-statement encoding.** `PB.Pipeline.Serialise` sets no `constructorTagModifier`, so
the `"tag"` value on every node is the **literal Haskell constructor name** — `BsRaw`, `BsIf`,
`ExCall`, etc, never lowercased or renamed. Two encoding shapes (see the doc comment atop
`PB.AST.Expr`):

- A constructor with **one positional field** wraps its payload in `"contents"`:
  `BsRaw Text` → `{"tag":"BsRaw","contents":"<source text>"}`;
  `ExRaw [Text]` → `{"tag":"ExRaw","contents":["tok1","tok2"]}`.
- A constructor with **multiple named fields** (record syntax, e.g. `ExCall{callee,callArgs}`)
  flattens those fields alongside `"tag"` — no `"contents"` wrapper. Field names go through
  `stripCamelCasePrefix` (`callArgs` → `args`, `ifThen` → `then`, `forBody` → `body`, etc).
- Every body statement is `Located BodyStmt`, serialized as **`{"line": Int, "node": {...}}`** —
  always unwrap `"node"` to reach the tagged value, at every nesting level (top-level statements
  _and_ everything inside `then`/`elseIfs`/`else`/`body`/`clauses`).

Do not hand-roll a walker that special-cases field names per constructor — it is fragile to
exactly this kind of schema drift (this bit us once: see BACKLOG's `pb index` SQL-extraction
entry). Use the AST walker pattern which recurses into every dict value and list
item unconditionally and can't miss a tag regardless of which field a constructor nests its
children under.

If you need ground truth on the wire format, don't trust committed example JSON (`output/` is
gitignored scratch and may be stale) — rebuild and run the binary directly:

```bash
(cd compiler && cabal build)
BIN=$(cd compiler && cabal list-bin pbc)
"$BIN" -i <dir-with-one-srf> -o /tmp/pbout && python3 -m json.tool /tmp/pbout/*.json
```

**Canonical cabal invocation:** always run cabal from the `compiler/` directory (either `cd compiler && cabal …` or `(cd compiler && cabal …)` from the repo root). This picks up both `cabal.project` at the repo root and `compiler/cabal.project.local` (which sets the duckdb-ffi library paths). Build output goes to `dist-newstyle/` at the repo root. Never use `--project-dir compiler` from the repo root — that skips `cabal.project.local` and loses the duckdb library paths.

**BACKLOG entries for BsRaw work are pre-loaded with Stage 0 analysis.** Each open BsRaw item records: current count, root cause (token kind + guard line), which shapes must stay BsRaw, and the Stage 1 fix sketch. Confirm the counts still match the script output, then proceed directly to Stage 1 — no re-sampling required.

---

## Prelude and Safety Rules

The custom Prelude is in `compiler/src/PB/Prelude.hs`. These rules are non-negotiable.

| Rule                 | Detail                                                                                      |
| -------------------- | ------------------------------------------------------------------------------------------- |
| `Text` everywhere    | No `String` in exposed APIs; `OverloadedStrings` is set                                     |
| No partial functions | `head`, `tail`, `(!!)`, `fromJust`, `read`, `cycle`, `maximum`, `minimum` are hidden        |
| No `undefined`       | Hidden from Prelude; use `error "impossible: <reason>"` only when GHC cannot prove totality |
| Text IO              | `putStr`/`putStrLn`/`readFile` re-exported from `Data.Text.IO`                              |

All new modules must start with `import PB.Prelude` under `NoImplicitPrelude` (set in `common-settings` in the cabal file).

`cabal build` must be warning-free. `-Wall` and `-Wincomplete-patterns` are set. Incomplete pattern matches are a hard error.

---

## General Coding Guidance

- **Megaparsec `try` invariant:** In a `choice`, every alternative that can consume input before failing must be wrapped in `try`. Without it, a partial match (e.g. consuming a sign character before failing on a non-digit) propagates the error and skips all remaining alternatives. Audit any `choice` whose alternatives share a leading character.
- Always prefer short, flattened code - no huge monolithic functions
- Always rename Aeson serialized fields ergonomic JSON (not just the raw Haskell names)
- compiler/app/Main.hs should have no functionality other than to call into compiler/src/PB/Pipeline/Runner.hs. Three modes: (1) `-i SRC -o DIR` per-file JSON, (2) `-i SRC --jsonl` streaming JSONL, (3) `-i SRC --db FILE` DuckDB-direct (passes 1–8 all in Haskell). No logic other than flag parsing and dispatch.
- Accept no hacky solutions or greedy operations that will cause pain down the line: if we can't reliable detect the beginning / end of a regions (e.g., FUNCTION / END FUNCTION), we can't start working on it yet.
- Be creative and comprehensive in generating PBT and pathological unit test cases; PB has lots of issues like `foo()bar()` smashed together ` & // comment`
- Ensure the preprocess step is principled and resilient
- We always strongly type everything we can. E.g., in a DataWindow we will see `..(retrieve="..SQL string", ...)`. Rather than a map of properties, we should have an explicit record type that captures the possible known fields.
- **Identifier typing is a standing goal, not a cost/benefit call.** Any AST field that structurally holds a PB identifier — or a fixed-arity compound of identifiers, e.g. `TypeDecl`'s ancestor-class + optional-override — must be `Ident`/`IdentSet`/`Lvalue`, never raw `Text`/`[Token]`. This holds **regardless of how many consumers currently read the field** — "only one call site needs it" is not a reason to leave it untyped. Do not apply the root CLAUDE.md's "no premature abstraction" rule to this category; that rule is about not inventing behavior nobody asked for, and typing an identifier correctly is not new behavior, it's removing a latent footgun (raw `Text`/`Token` equality is case-sensitive; PB identifiers are not). The only valid reasons a field stays `Text`/`[Token]`: (a) genuinely unparsed/raw source (`BsRaw`, embedded SQL, arg-token lists not yet parsed into `Expr`), (b) a PB keyword or grammar-literal comparison (e.g. checking a token equals the literal keyword `structure`) — not an identifier reference, (c) the value isn't structurally an identifier or a small fixed compound of them (free-form text, a rendered display string). When in doubt, name the specific reason in the Stage 1 proposal rather than defaulting to "leave it as Text since nothing else reads it yet."

---

## Testing Discipline (Haskell)

**Test structure.** Always use `testGroup` with a descriptive path so failures self-locate:

```haskell
testGroup "Pipeline"
  [ testGroup "Preprocess"
    [ testCase "continuation across 3+ lines" $ ...
    , testCase "continuation with escaped quotes" $ ...
    ]
  ]
```

**Stub format.** Write real assertions wherever possible. Use `assertFailure "unimplemented: <reason>"` only when the production function does not exist yet and a stub is needed to make the project compile:

```haskell
testCase "some thing" $ assertFailure "unimplemented: continuation across 3+ lines"
```

Replace it with a real assertion before Stage 3 — a test that permanently says "unimplemented" is not a test.

**HUnit vs Hedgehog:**

- `testCase`: specific named examples, edge cases, regression tests
- `testProperty`: invariants that must hold for all (generated) inputs

**Early Hedgehog invariants** (from README):

- idempotence: `normalize (normalize x) == normalize x`
- monotonicity: `llStartLine <= llEndLine`
- no logical line ends with `&`
- string literal parity preserved

**Megaparsec exploration.** Use `parseTest` from `Text.Megaparsec` in the REPL to get human-readable failure output. In tests, use `parse` with `assertBool`/`assertEqual` and a descriptive message.

**Structuring.** Keep test files short and have a master test runner in `test/Main.hs` that imports and aggregates them. Keep PBT and unit tests separate. Don't refer to "phase numbers" or anything like that which has temporal implications, just give everything logical names.

**Triangulation for parser constructs.** Every new parser needs at least three test shapes:

- Positive: valid input → expected AST
- Negative: invalid input → parse failure (not a crash)
- Property: at least one Hedgehog invariant

---

## Reference Docs

The parser specification is in `doc/spec.md` — consult it first for any question about lexical rules, token forms, file structure, or DataWindow syntax. It is synthesized from the battle-tested reference implementation and amended with corrections from the official Appeon docs.

**`doc/pb2025r2/` is a full local mirror of the official Appeon PowerBuilder 2025 R2 help docs** (`objects_and_controls/`, `datawindow_reference/`, `powerscript_reference/`, `datawindow_programmers_guide/`, etc. — one subdirectory per manual). `grep -rn` it directly for any question about builtin system-class hierarchy, control/DW properties-events-functions, or PowerScript syntax before searching the web — it's faster and it's the authoritative source `doc/spec.md` itself is amended against. Individual per-function reference pages often state their inheritance directly (e.g. a DataWindow function's own page saying "Inherited from DragObject"), which is more reliable than the hierarchy diagrams in `objects_and_controls/`, several of which are images, not extractable text.

**When the corpus contradicts SPEC.md, the corpus wins.** Real exported files are ground truth. Update SPEC.md to document the discrepancy before or alongside the parser fix — do not silently accept corpus patterns without recording them in the spec.

---

## Corpus Coverage Checklist

Every distinct top-level construct found in the 515 non-DataWindow corpus files.
Mark done/pending as body parsers land.

| Construct                               | File types | Status  |
| --------------------------------------- | ---------- | ------- |
| `forward … end forward`                 | .srw, .sru | done    |
| `forward prototypes … end prototypes`   | .srw, .sru | done    |
| `type prototypes … end prototypes`      | .srf, .sru | done    |
| `prototypes … end prototypes`           | .srf       | done    |
| `global variables … end variables`      | .srw, .sru | done    |
| `type variables … end variables`        | .srw, .sru | done    |
| `global type … end type`                | .srw, .sru | done    |
| `public function … end function`        | .srw, .sru | done    |
| `protected subroutine … end subroutine` | .srw, .sru | done    |
| `on … end on`                           | .srw, .sru | done    |
| `event … end event`                     | .srw, .sru | done    |
| `type … end type` (TypeBlock)           | .srw, .sru | done    |
| Body: `if … end if`                     | all        | done    |
| Body: `choose case … end choose`        | all        | done    |
| Body: `for … next`                      | all        | done    |
| Body: `do … loop`                       | all        | done    |
| Body: `try … catch … end try`           | all        | done    |
| Body: embedded SQL                      | .srw, .sru | pending |
| Body: assignment / call statements      | all        | done    |

---

## Module Placement

| Module          | Purpose                                                                                                                                                                                                                                            |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PB.AST.*`      | Data types only — no parsing logic (Located, Expr, BodyStmt, Type, SourceFile, DataWindow)                                                                                                                                                         |
| `PB.Lexing.*`   | Tokenization, layout, string mode                                                                                                                                                                                                                  |
| `PB.Grammar.*`  | megaparsec parsers (Body, File, Stream, DataWindow)                                                                                                                                                                                                |
| `PB.Compile.*`  | Compilation pipeline: SSA IR (SSA), IR types (IR), loop analysis (LoopAnalysis), SSA lowering (FromSSA), flattening (Flatten), instruction types (InstrTypes), value model (ValueModel), interpreters (Interp, InstrInterp)                        |
| `PB.Pipeline.*` | Multi-step transformations: Preprocess, Emit, Passes, Runner, Serialise, FileWalk, DuckDb, SqlParse, Church                                                                                                                                        |
| `PB.Analysis.*` | Pure analysis passes: Cfg, Dataflow, Taint, TypeEnv, TypeResolve, Builtins, SchemaCategory, SchFootprint, DwFootprint, ControlHierarchy. `PB.Analysis.Rules.*` holds the Soufflé rule sets + typed EDB-reshaping readers (DeadCode, Taint, Schema) |
| `PB.Prelude`    | Custom Prelude — no parsing or transformation logic                                                                                                                                                                                                |

New modules go in the most specific matching directory. If a new layer is needed, propose it in Stage 1.

---

## Datalog Rule Placement Discipline (Plan 170)

Read this before writing or reviewing any Souffle EDB view (`initXEdbViews`
in `PB.Analysis.Rules.*`), materializer SQL (`materialize*` in
`PB.Pipeline.DuckDb`), or Datalog rule. Governs where logic lives across the
four surfaces a whole-program analysis touches: compiler phases
(`PB.Grammar`/`PB.AST`/`PB.Compile`), `PB.Analysis.*` Haskell, EDB-view SQL,
and Souffle Datalog rules (`PB.Pipeline.Souffle`/`PB.Analysis.Rules.*`).

**History.** The original `PB.Pipeline.Datalog` (a hand-rolled DuckDB
`WITH RECURSIVE` rule compiler — `stratify`/`compileBody`/`compileRule`,
since deleted) was built from scratch on a misreading of project direction
as "avoid Souffle." `PB.Pipeline.Souffle`'s current `Rule`/`RuleSet` IR
(literal-text rules, a `ruleRefs` list the caller must hand-sync) and the
EDB-view-heavy pattern in `PB.Analysis.Rules.*` partly inherit that
detour's shape rather than being chosen specifically for Souffle. Treat
them as legacy defaults open to revision (see `doc/plan/172-categorical-
datalog-layer.md`), not settled precedent.

**The three-question placement test.** For any new piece of logic:

1. Is it true of ONE thing in isolation (one AST node/statement/procedure),
   computable without an unbounded walk over the corpus? → a compiler phase
   (syntax-only, single-file) or `PB.Analysis.*` Haskell (may need
   cross-file context — `ControlIndex`/`WorkspaceEnv`/DDL catalog — but
   still a bounded fold, never a fixpoint). Test with hand-typed HUnit
   fixtures.
2. Does answering it require an unbounded walk, a fixpoint, a count,
   stratified negation, or picking a winner among competing derived facts?
   → a Souffle Datalog rule. "Picking a winner among competing facts" is
   the one people miss — that's what `choice-domain` and rule
   specialization are _for_; it is not a SQL `CASE`'s job. Test via
   `SouffleTest.hs`-style fixtures against the real `souffle` CLI.
3. Otherwise — moving an already-computed fact from storage shape into
   relation shape (rename, cast, static-predicate filter, union of
   identically-shaped sources) — it's a typed `PB.Analysis.Rules.*` Haskell
   function, materialized into a plain DuckDB table via
   `recreateTextTable`/`appendTextRows` (amended 2026-07-15 per Plan 175,
   backed by that plan's Phase 1 real-corpus gate; this destination used to
   be "an EDB view" — a `CREATE VIEW` string — before that evidence landed).
   `PB.Analysis.Rules.Schema`'s `legSourceRows`/`stmtRows`/`seedRows` (feeding
   `querySchemaObjects`/`querySchemaMorphismRows`), `PB.Analysis.Rules.DeadCode`'s
   `procRows`/`procMetaRows`/`inheritsRows`/`callRefRows`/`resolvedCallEdgeRows`/
   `entryRows`/`callsRows`, and `PB.Analysis.Rules.Taint`'s
   `taintEdgeIntraRows`/`taintEdgeArgRows`/`taintEdgeGlobalRows`/
   `taintEdgeReturnRows`/`taintKeyRows` are the reference pattern. Every
   `initXEdbViews` in `PB.Analysis.Rules.*` is now a typed Haskell
   materializer — no `CREATE VIEW` SQL remains in this layer; do not write
   a _new_ `CREATE VIEW` for rule-3-shaped logic anywhere in the codebase
   going forward.

**House rule: EDB reshaping logic may not decide anything.** A typed
`PB.Analysis.Rules.*` reshaping function (or a not-yet-migrated legacy
`CREATE VIEW` in `initXEdbViews`, or a materializer's `INSERT ... SELECT`)
may only rename, cast, or filter by a static/structural predicate. If the
logic needs a `CASE`/branch, `ROW_NUMBER`/any window function, or a
`GROUP BY`/aggregate to produce its answer, that is a decision (question 2's
territory — a tie-break, a label, a count) and does not belong here. Move it
into a Datalog rule (`choice-domain` for tie-breaks, rule specialization for
labels, Souffle's own `count :` aggregate). This rule exists because every
real bug found in the Datalog substrate to date — `leg`'s writes-vs-retrieve
tie-break, `decomposition_coslice`'s direction-interleaved ordinals,
`taint_paths`' `step_kind` mislabeling of 0-hop paths — lived in exactly
this kind of logic, caught only by real-corpus/real-UI spot checks, never by
a test that ran before the fact. See
`doc/plan/171-datalog-decision-migration.md` for the concrete migration of
the two still-open instances.

**Adversarial fixture requirement.** Any test-fixture set for a
Datalog-backed relation must cover, not just the "interesting" connected
case: (a) a duplicate-key collision (two facts competing for the same
derived key), (b) a 0-hop/degenerate case (source == sink, self-loop), (c)
a cycle not passing through the seed, where structurally possible for that
relation. All three shapes have independently caused a real, shipped bug in
this project and none were caught by the fixtures that existed at the time
— a new relation's test group is incomplete without them.

**Roadmap.** `doc/plan/170-datalog-discipline.md` is the index (history,
rationale, and links to the concrete follow-on plans); this section is the
enforceable summary and takes precedence if the two ever drift.

---


## Module Signature Lookup

There is no hand-maintained module-signature index in this file — a prior
version had one, but at this codebase's size (60+ modules, ~18k lines) it
went stale faster than sessions kept it current, including gaps in the
modules under most active development. Locate signatures the same way the
Token Efficiency section already prescribes for everything else:

```text
rg -n "functionName" src/
rg -l "TypeName" src/
```

`rg -l` to find the file, `rg -n` to find the line, then `Read` with
`offset`/`limit` around that line rather than the whole file.

---

## Appender-pool failure modes (Plan 182b follow-up, 2026-07-18)

Two silent `appender_flush` failure modes have bitten the `--db` pipeline. Both
surface only at pool teardown (`withAppenderPoolTimed`'s `destroyAll` flush), not
at the `append_*` call — so a clean per-file append gives no warning and the
whole corpus run dies at the end with a bare `DuckDB appender error in
appender_flush` and no table/row context.

1. **Missing `endRow` in a row-marshalling sequence (the 182b bug).** Every
   `append*` function's body must finalize each row with `endRow app`
   (`c_duckdb_appender_end_row`). If it doesn't, the N `aText`/`aInt`/…
   calls for a row are never finalized; the *next* row's values keep advancing
   the appender's column counter, so by flush time the buffered chunk has
   N×columns against a table with `columns` → a column-count mismatch that
   DuckDB only validates at flush. Symptom: `taint-corpus-bench` dies at
   teardown with `appender_flush` after a clean parse; BFS/algebraic parity is
   never reached. **Fix (now structural, not a thing to remember):** every
   `append*` routes its per-row column marshalling through `forEachRow`
   (`PB.Pipeline.DuckDb`), which brackets `endRow app` via `bracket_` so a
   forgotten `endRow` is impossible — a new `append*` that calls `forEachRow`
   can never reintroduce this. The row-marshalling sequence
   (`aText`/`aInt`/`aMaybeText`/`endRow`) is the invariant Plan 169 calls out
   as "unchanged" when an `append*` moves from `withRaw` to the pool;
   `forEachRow` preserves it mechanically.

2. **Table written by `append*` but missing from `phaseATables` (the first
   182b bug, already fixed).** `appendRow` does `Map.lookup tbl pool` and
   throws `impossible: appender pool missing table <t>` if the table isn't in
   `phaseATables` (`Runner.hs`). That one fails loudly at the first append, not
   at flush — but it's the same class: a new `append*` + table needs BOTH the
   `CREATE TABLE` in `initSchema` AND the name in `phaseATables`.

**Diagnose fast next time.** `checkAppenderSt` (in `PB.Pipeline.DuckDb`) now
replaces the bare `checkSt` at both flush sites (`destroyAll` pool teardown and
the `withAppender` path). On a non-zero DuckDB status it pulls the real
libduckdb error string via `c_duckdb_appender_error_data` (current FFI; the
deprecated `c_duckdb_appender_error` is not re-exported by `Database.DuckDB.FFI`)
and reports it together with the failing table name, e.g.
`DuckDB appender error in appender_flush:taint_intra_edges: <real libduckdb message>`.
If you ever see the old bare `DuckDB appender error in appender_flush` with no
`:<table>:` suffix, that's the non-pool `withAppender` path or a code path still
on `checkSt` — switch it to `checkAppenderSt`. To bisect without the helper,
temporarily flush each Phase A appender individually (`c_duckdb_appender_flush`
in a `for_` over `Map.toList pool`) and watch which table errors first; or grep
the suspect `append*` for a missing `endRow app`.

Cross-reference: the appender-pool design (pooled create-once / flush-at-boundary,
`phaseATables`, `appendRow`) is `doc/plan/169-appender-reuse-and-effterm-sharing.md`.
The `endRow` requirement is part of that plan's "row marshalling code … is
unchanged" invariant — this 182b incident is the concrete case where it was
violated on a newly-added `append*`, and `forEachRow` is the mechanical guard
that now keeps it invariant.
```
