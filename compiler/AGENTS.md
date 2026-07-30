# PB Compiler (Haskell) — Subsystem Guide

Loaded automatically by Claude Code whenever a session reads or edits files under
`compiler/`. This file covers Haskell/parser-specific rules only — session
protocol, the staged verification loop, commit discipline, documentation
style, and change-scope rules live in the root `AGENTS.md` and apply here too.

**Run the `constraint-evasion` skill (`.claude/skills/constraint-evasion/SKILL.md`)
on every diff under `compiler/`** — before `/finish`, before proposing a
commit, and any other time a Haskell diff here is being reviewed. It checks
for suppressed warnings/hlint ignores, string/field/sentinel stuffing into
existing types, and type signatures weakened relative to plan or prior code
— including in code the diff didn't touch but should have. This is mandatory,
not optional, for this subsystem.

**Read the `ident-minting` skill (`.claude/skills/ident-minting/SKILL.md`)
before touching anything Ident-minting-shaped** — adding or removing a
`mkIdent`/`mkIdentAt`/`mkIdentDerived`/`mkIdentSynthetic` call, deciding
whether a `Text`/`[Token]` field should become `Ident`/`IdentSet`/`Lvalue`,
or judging a "caller bridges via `identOrig` then the callee re-mints via
`mkIdent`" gap. It's the worked decision procedure for the two standing
rules below (identifier typing, parse-time-only minting), including the
widen-vs-leave-Text split when only some callers of a shared function
already hold a real `Ident`.

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
- **Identifier typing is a standing goal, not a cost/benefit call.** Any AST field structurally holding a PB identifier — or a fixed-arity compound of identifiers, e.g. `TypeDecl`'s ancestor-class + optional-override — must be `Ident`/`IdentSet`/`Lvalue`, never raw `Text`/`[Token]`, regardless of how many consumers currently read the field ("only one call site needs it" doesn't apply). The root AGENTS.md's "no premature abstraction" rule doesn't apply here either: that rule targets inventing unasked-for behavior, and typing an identifier correctly isn't new behavior — it removes a latent footgun (raw `Text`/`Token` equality is case-sensitive; PB identifiers are not). Valid reasons a field stays `Text`/`[Token]`: (a) genuinely unparsed/raw source (`BsRaw`, embedded SQL, arg-token lists not yet parsed into `Expr`); (b) a keyword/grammar-literal comparison, not an identifier reference (e.g. a token equals the literal keyword `structure`); (c) the value isn't structurally an identifier or a small fixed compound of them (free-form text, a rendered display string). When in doubt, name the specific reason in the Stage 1 proposal rather than defaulting to "leave it as Text."
- **`Ident`s are minted only at parse time.** Every `Ident` should trace back to `mkIdentAt`/`mkIdent` called directly on a real token during parsing (`PB.Grammar.*`) — never re-minted later from `Text` that was itself flattened from an earlier `Ident` (a DB round trip, a `PhaseAData` accumulation, any other storage shape). Recovering a real span and bridging through `mkIdentAt`/`mkIdentSynthetic` (`rowIdent` in `PB.Pipeline.Passes.fetchResolveInputs`) is the accepted exception, reserved for a fact with no other in-memory source by the time the consumer needs it — not a general license to keep re-minting wherever a span column can be added. Before adding a span-bridge fix to a "DB-round-tripped `Text` → `mkIdent`" gap, grep every consumer of the underlying AST field (e.g. `tdAncestorClass`, `fnsName`) for one that already computes the same fact once, in-memory, from real parse-time `Ident`s (`PB.Analysis.TypeEnv.WorkspaceEnv` is the usual home) — if one exists, thread it through instead of bridging the redundant path into span-correctness. Reference case: `PB.Pipeline.Passes.fetchResolveInputs`'s `riInherits`/`riProcMap`/`riCallableProcMap` used to re-derive from `ObjectRow`/`ProcRow` via `mkIdent`; fixed by threading `WorkspaceEnv`'s already-correct `weHierarchy`/`weProcMap`/`buildCallableProcMap` straight through instead.

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

All top-level constructs (`forward`/`prototypes`/`variables`/`global type`/
function/subroutine/`on`/`event`/`type` blocks) and body statements (`if`,
`choose case`, `for`/`next`, `do`/`loop`, `try`/`catch`,
assignment/call) parse across the 515 non-DataWindow corpus files. The one
open gap: **embedded SQL body statements** (`.srw`/`.sru`) are not
grammar-parsed — they stay `BsRaw` (unparsed raw text).

---

## Module Placement

| Module          | Purpose                                                                                                                                                                                                                                            |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PB.AST.*`      | Data types only — no parsing logic (Located, Expr, BodyStmt, Type, SourceFile, DataWindow)                                                                                                                                                         |
| `PB.Lexing.*`   | Tokenization, layout, string mode                                                                                                                                                                                                                  |
| `PB.Grammar.*`  | megaparsec parsers (Body, File, Stream, DataWindow)                                                                                                                                                                                                |
| `PB.Compile.*`  | Compilation pipeline: SSA IR (SSA), IR types (IR), loop analysis (LoopAnalysis), SSA lowering (FromSSA), flattening (Flatten), instruction types (InstrTypes), value model (ValueModel), interpreters (Interp, InstrInterp)                        |
| `PB.Pipeline.*` | Multi-step transformations: Preprocess, Emit, Passes, Runner, Serialise, FileWalk, DuckDb, SqlParse, Church. `PB.Pipeline.DuckDb` is the opaque `Handle`/`Config` moat core plus the generic TEXT-table bridge and shared appender primitives; siblings `DuckDb.Appender` (pool lifecycle), `DuckDb.PhaseA` (Phase A row types/appenders), `DuckDb.PhaseB.Query`/`DuckDb.PhaseB.Append` (Phase B queries/appenders), `DuckDb.Materialize` (all `materialize*` SQL), and `DuckDb.Relations` (typed relation-reshaping readers) hold the rest |
| `PB.Analysis.*` | Pure analysis passes: Cfg, Dataflow, Taint, TypeEnv, TypeResolve, Builtins, SchemaCategory, SchFootprint, DwFootprint, ControlHierarchy, TaintClosure, DeadCodeReachability, SchemaClosure. `PB.Pipeline.DuckDb.Relations` holds the typed relation-reshaping readers (DeadCode, Schema, Taint fanouts) |
| `PB.Prelude`    | Custom Prelude — no parsing or transformation logic                                                                                                                                                                                                |

New modules go in the most specific matching directory. If a new layer is needed, propose it in Stage 1.

---

## DuckDb Moat & Analysis Placement

Read this before writing or reviewing any relation reader (`initXRelations` in
`PB.Pipeline.DuckDb.Relations`), materializer SQL (`materialize*` in
`PB.Pipeline.DuckDb.Materialize`), or analysis closure (`PB.Analysis.*`).
Governs where logic lives across the surfaces a whole-program analysis
touches: compiler phases (`PB.Grammar`/`PB.AST`/`PB.Compile`), `PB.Analysis.*`
Haskell, the DuckDb relation-loading boundary (`PB.Pipeline.DuckDb.Relations`),
and the SQL materializers (`PB.Pipeline.DuckDb.Materialize`).

**The DuckDb moat.** `PB.Pipeline.DuckDb.Relations` is the single boundary
that loads raw DuckDB tables into the typed row shapes the analyses consume.
It holds the pure relation-reshaping readers — `legSourceRows`/`stmtRows`/`seedRows`
(feeding `querySchemaObjects`/`querySchemaMorphismRows`),
`procRows`/`procMetaRows`/`inheritsRows`/`callRefRows`/`resolvedCallEdgeRows`/
`entryRows`/`callsRows`, and the `DefUseFanout` taint fanouts. These
functions only rename, cast, or statically filter; they never decide.

**The three-question placement test.** For any new piece of logic:

1. Is it true of ONE thing in isolation (one AST node/statement/procedure),
   computable without an unbounded walk over the corpus? → a compiler phase
   (syntax-only, single-file) or `PB.Analysis.*` Haskell (may need
   cross-file context — `ControlIndex`/`WorkspaceEnv`/DDL catalog — but
   still a bounded fold, never a fixpoint). Test with hand-typed HUnit
   fixtures.
2. Does answering it require an unbounded walk, a fixpoint, a count,
   or picking a winner among competing derived facts? → a Haskell closure in
   `PB.Analysis.*` (use `PB.Algebra.Closure`/`Semiring` when it is a real
   semiring closure; otherwise a plain worklist/BFS fold). A deterministic
   tie-break is analysis Haskell, not SQL `CASE`. Test with hand-typed
   HUnit fixtures.
3. Otherwise — moving an already-computed fact from storage shape into
   relation shape (rename, cast, static-predicate filter, union of
   identically-shaped sources) — it's a typed `PB.Pipeline.DuckDb.Relations`
   function, materialized into a plain DuckDB table via
   `recreateTextTable`/`appendTextRows` (both in `PB.Pipeline.DuckDb`, the
   moat core every `DuckDb.*` submodule imports).
   `PB.Analysis.TaintClosure`'s
   `materializeTaintClosure`/`materializeTaintStepKind` (reshaping
   `PB.Analysis.TaintClosure`'s closure output directly into
   `taint_reaches`/`taint_confirmed`/`taint_step_kind`) are the reference
   pattern. No `CREATE VIEW` SQL belongs in this layer; do not write a
   _new_ `CREATE VIEW` for rule-3-shaped logic anywhere in the codebase
   going forward.

**House rule: relation reshaping logic may not decide anything.** A typed
`PB.Pipeline.DuckDb.Relations` reshaping function (or a materializer's
`INSERT ... SELECT`) may only rename, cast, or filter by a
static/structural predicate. If the logic needs a `CASE`/branch,
`ROW_NUMBER`/any window function, or a `GROUP BY`/aggregate to produce its
answer, that is a decision (question 2's territory — a tie-break, a label,
a count) and does not belong in SQL. Move it into analysis Haskell (a
deterministic tie-break) or, if it is a pure projection over already-computed
analysis output, into a `materialize*` in `PB.Pipeline.DuckDb`. This rule
exists because every real bug found to date — `leg`'s writes-vs-retrieve
tie-break, `decomposition_coslice`'s direction-interleaved ordinals,
`taint_paths`' `step_kind` mislabeling of 0-hop paths — lived in exactly
this kind of logic, caught only by real-corpus/real-UI spot checks, never by
a test that ran before the fact.

**Adversarial fixture requirement.** Any test-fixture set for a
relation must cover, not just the "interesting" connected case: (a) a
duplicate-key collision (two facts competing for the same derived key), (b) a
0-hop/degenerate case (source == sink, self-loop), (c) a cycle not passing
through the seed, where structurally possible for that relation. All three
shapes have independently caused a real, shipped bug in this project and none
were caught by the fixtures that existed at the time — a new relation's test
group is incomplete without them.

**Roadmap.** `doc/plan/183-duckdb-moat-restructure.md` is the index
(history, rationale, and links to the concrete follow-on plans); this section
is the enforceable summary and takes precedence if the two ever drift.

---

## DuckDB Schema Standards

Read this before renaming, adding, or restructuring any DuckDB column or
table — whether in `initSchema` (`PB.Pipeline.DuckDb`), a `materialize*`
(`PB.Pipeline.DuckDb.Materialize`), or a Phase A/B row/appender type.

**Naming conventions.** The schema already converges on these; a new table
follows them rather than inventing a local convention:

- One identity concept, one column name, everywhere. The PB object/DataWindow
  name is always `object`; a procedure name is always `proc_name`. No table
  uses `dw_name`, `from_proc`, or any other synonym for either concept —
  check `doc/architecture-pipeline.md`'s §5 schema listing for the current
  canonical set before introducing a new identity column.
- Asymmetric relationships get role-prefixed column groups, not a bare
  generic pair. `taint_paths`' `file`/`target_file` (source vs. sink) and
  `decomposition_coslice`'s `seed_`/`target_`/`leg_from_`/`leg_to_` (four
  roles of the same underlying `(kind, namespace, table_name, column_name)`
  shape) are the reference pattern — a `from`/`to` pair with no further
  qualification is ambiguous the moment a third role shows up.
- Don't leave a structured key string-encoded when the fields it encodes are
  already available from another table. `schema_objects` is the physical
  `(kind, namespace, table_name, column_name, stmt_*)` row behind every
  `*_key` string in this schema; a consumer that needs those fields joins
  back to `schema_objects` rather than parsing the key.
  `decomposition_coslice`'s `seed_key`/`target_key`/`leg_from`/`leg_to`
  decomposition is the reference pattern — do not write a new
  `_parse_object_key`-style string-parsing helper anywhere in `cli/` or
  `ui/`.
- No `CREATE VIEW` for new derived data — this restates the Moat & Analysis
  Placement rule above; `all_sql_tables` is the one grandfathered exception,
  not a precedent.

**A rename or new column is not done until it has landed in every layer that
names it, in the same session:**

1. `compiler/src/PB/Pipeline/DuckDb.hs` (`CREATE TABLE`) and any sibling
   `DuckDb.*` module with a matching `SELECT`/row type (`PhaseA`,
   `PhaseB/Query`, `PhaseB/Append`, `Materialize`, `Relations`)
2. `cli/` row builders, pydantic models, and any hand-written SQL string that
   names the column
3. `queries/*.sql` (the saved-query catalogue — outside `cli/`, easy to miss
   with a `cli/`-scoped grep)
4. `ui/packages/platform/src/types/api.ts` and any component reading the
   field, if the column reaches the JSON wire format
5. `doc/architecture-pipeline.md`'s §5 schema listing — the compact
   canonical reference every session should read instead of `initSchema`; a
   rename that skips this line reintroduces the exact drift this section
   exists to prevent

Grep all five before proposing the change, not just the layer where the need
was discovered — Plan 198's Phases C, D, and G each found real consumers
outside the initial grep (a `queries/*.sql` file, a `ui/` type, a stale doc
line) that would otherwise have shipped silently wrong or gone silently
stale. State the full consumer list in the Stage 1 proposal per the root
`AGENTS.md`'s "Multi-file changes require Stage 1 review" rule — a schema
rename is definitionally a multi-file, multi-layer change.

**Schema-shape lookups: read `doc/architecture-pipeline.md`'s §5, not
`initSchema`.** It is a compact, accurate mirror of the real schema —
reading it costs a fraction of reading `DuckDb.hs`'s `initSchema` plus every
sibling module's row types, and is enough to write or review a query. Fall
back to `initSchema` only when actually authoring a schema change (item 1
above), or when a query against a documented table returns an unexpected
column-not-found error — which means the doc has drifted and needs the same
correction this section asks new schema changes to make in the first place.

**Roadmap.** `doc/plan/198-duckdb-schema-consolidation.md` is the concrete
precedent this section generalizes — read it for the specific renames
(`dw_name`→`object`, `from_proc`→`proc_name`, `source_*`/`sink_*`→
`file`/`target_*`) and the `schema_objects` join-back pattern in full detail.

---

## Appender-pool failure modes

Two silent `appender_flush` failure modes can bite the `--db` pipeline. Both
surface only at pool teardown (`withAppenderPoolTimed`'s `destroyAll` flush),
not at the `append_*` call — a clean per-file append gives no warning, and
the whole corpus run dies at the end with a bare `appender_flush` error and
no table/row context.

1. **Missing `endRow` in a row-marshalling sequence.** Every `append*`
   function must finalize each row with `endRow app`
   (`c_duckdb_appender_end_row`). Without it, the row's `aText`/`aInt`/…
   calls never finalize; the _next_ row's values keep advancing the
   appender's column counter, so by flush time the buffered chunk has
   N×columns against a table with `columns` — a column-count mismatch
   DuckDB only validates at flush. **Structural guard:** every `append*`
   routes its row marshalling through `forEachRow` (`PB.Pipeline.DuckDb`),
   which brackets `endRow app` via `bracket_` so a new `append*` calling it
   can't omit `endRow`.
2. **Table written by `append*` but missing from `phaseATables`.**
   `appendRow` does `Map.lookup tbl pool` and throws `impossible: appender
   pool missing table <t>` if the table isn't in `phaseATables`
   (`Runner.hs`) — fails loudly at the first append, not at flush. A new
   `append*` + table needs both the `CREATE TABLE` in `initSchema` and the
   name in `phaseATables`.

**Diagnosing a bare `appender_flush` error:** `checkAppenderSt`
(`PB.Pipeline.DuckDb`) replaces the bare `checkSt` at both flush sites
(`destroyAll` pool teardown and `withAppender`). On a non-zero DuckDB status
it pulls the real libduckdb error string via `c_duckdb_appender_error_data`
and reports it with the failing table name, e.g. `appender_flush:
taint_intra_edges: <real libduckdb message>`. A bare error with no `:<table>:`
suffix means some code path is still on `checkSt` — switch it to
`checkAppenderSt`. To bisect without it, flush each Phase A appender
individually (`c_duckdb_appender_flush` over `Map.toList pool`) or grep the
suspect `append*` for a missing `endRow app`.

History and full appender-pool design (pooled create-once /
flush-at-boundary, `phaseATables`, `appendRow`):
`doc/plan/169-appender-reuse-and-effterm-sharing.md`.
