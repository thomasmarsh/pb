# pb-compiler — Working Protocol

## Quick Reference

```text
cd compiler && cabal build                          # compile library + executables
cd compiler && cabal build --enable-tests           # compile tests too
cd compiler && cabal test                           # run test suite
cd compiler && cabal test --test-show-details=direct # verbose output
./pb check-corpus                    # 0 errors / 1053 files = baseline
cd cli && uv run pytest lib/tests/ pipeline/tests/ api/tests/  # Python tests
cd cli && uv run ruff check     # Python lint
cd cli && uv run pyright        # Python type check (0 errors baseline)
cd ui && pnpm typecheck         # TypeScript type check (explorer)
cd ui && pnpm lint              # ESLint (explorer)
cd ui && pnpm test              # Explorer reducer tests (64 tests)
cd ui && pnpm build             # Build explorer TS → static/dist/
PB_SQL_MOCK=1 uv run --project cli pb explore  # Run explorer with mock SQL (no MySQL needed)
```

## Session Start (read this every session)

1. **Read `doc/plan/BACKLOG.md` first** — the authoritative work queue. The
   user sets priority; confirm the charter matches the top unfinished item. Do
   not start work from `git status` alone.
2. **If the charter references a plan number** (e.g. "plan 111a"), read that
   plan file in `doc/plan/` _before_ touching `git`, glob, or any source. Plan
   files are the source of truth for scope, prerequisites, and the exact
   verify steps. They are gitignored (see below), so `git status` will never
   tell you they were updated.
3. **`doc/plan/` is gitignored.** Plan files, BACKLOG, and STRATEGY are _not_
   committed — they live only on disk. Grooming edits to them are real work
   but will never appear in a commit; the commit only carries code + tests.

**Interrupted-session recovery.** When asked to "continue" a prior session,
locate the plan file and read its "Status" / close-out section first — it
records what landed and what remains. Then check `git status` to see the
on-disk delta. Do not assume the on-disk state is correct: an interrupted
session may have left code that doesn't compile or tests that fail for the
wrong reason. Run `cabal build && cabal test` early to get ground truth before
deciding whether to continue or revert. (The 111a session left a test file
using `head`, which `PB.Prelude` hides — the plan file had the full picture,
but reading `git status` first wasted a step.)

**This file (`CLAUDE.md`) is the orientation layer.** Its Code Index mirrors
the real module signatures so you don't re-derive them by grepping source. If
you change a constructor or add a module and skip updating the index, the next
session pays for it — so treat index updates as part of "post-task grooming,"
not optional.

## Session Scoping

**Charter first.** Before Stage 0, state a one-sentence charter:

> "This session delivers X. [Y is out of scope.]"

Infer the charter from the user's intent. If ambiguous, ask before reading any code. No work starts until the charter is written.

**Scope is fixed for the session.** If new problems surface mid-session, log them to `doc/plan/BACKLOG.md` — do not expand the current session's scope without explicit user approval.

**Classifying new failures.** When a fix exposes additional failures:

- Same root cause as the current fix → fix it in this session (it is within charter)
- Different root cause → one-line entry in `doc/plan/BACKLOG.md`; continue with the current charter

**Primary failures hide secondary failures.** Corpus error counts are keyed on the _first_ failing line per file. A dominant failure mode can mask other bugs in the same file. Fix the primary mode, rerun the corpus check, then re-categorize the remaining errors before drawing conclusions.

**Stop condition.** Charter goal met + `cabal test` passes → stop. Do not pick up the next visible problem.

**Post-task grooming.** After the stop condition is met, before proposing the commit message, update planning artifacts to reflect new understanding:

- Mark completed BACKLOG items `[x]` with a short completion note and date.
- Update `doc/plan/STRATEGY.md`: current-state metrics, track status, recommended session order.
- Update any plan files (e.g. `doc/plan/20-dw-a1.md`) that reference superseded counts, signatures, or status.
- If the session revealed new scope, append to BACKLOG — do not silently discard the finding.

This grooming step is mandatory; do not skip it to save time.

**`doc/plan/BACKLOG.md`** is the authoritative work queue. The user sets priority order. The assistant only appends — never reorders. Read it at session start to confirm the charter matches the top unfinished item.

---

## The Staged Verification Loop

Scale gates to the size of the change. Trivial changes (typo, rename, single-line fix) may auto-proceed. Non-trivial changes stop at Stage 1 and optionally Stage 3.

### Stage 0 — Read First (always)

Before proposing any change, read every file that will be touched. Use `rg` to locate the relevant section before reading the full file:

```text
rg -n "functionName" compiler/src/
rg -l "LogicalLine" compiler/src/
```

No change is proposed without a prior read of all relevant modules. Locate callers before modifying a function.

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

**Confirm hypotheses with a narrow test before Stage 1.** After reading code and forming a theory, write a one-line `testCase` that asserts the correct output and run it. A test that currently fails is worth more than a long analysis. Do not skip this step.

### Stage 1 — Propose

A proposal must name:

- Function signatures being added or changed (with types)
- Test case names (not bodies) and which `testGroup` path they belong to
- Module placement for new code

**Non-trivial changes: stop here and wait for review.**

### Stage 2 — Failing Tests

Write tests first with real assertions expressing the correct behaviour. The tests must fail because the production code is wrong — not because the test itself is a placeholder. An import error is not a valid red phase for a TDD test. Verify:

```text
cabal build --enable-tests   # must compile cleanly
cabal test                   # tests must appear and fail, not error/crash
```

Similar for pnpm and pytest.

Do not proceed until tests are failing for the right reason.

Use `assertFailure "unimplemented: <reason>"` only when the unit under test does not exist yet and you need a temporary stub in the production code to keep the project compiling. Once the production stub exists, replace the `assertFailure` with a real assertion before Stage 3.

### Stage 3 — Implementation

Write the code. Before proceeding:

```text
cabal build   # must be warning-free; -Wall is set; warnings are blockers
```

**Non-trivial changes: stop here and confirm before running the test suite.**

### Stage 4 — Verify

```text
cabal test --test-show-details=direct
cd cli && uv run ruff check && uv run pyright && uv run pytest lib/tests/ pipeline/tests/ api/tests/
cd ui && pnpm lint && pnpm typecheck && pnpm test
```

All tests must pass. An unexpected failure is a regression — read it before changing anything.

---

## Evidence-Based Triangulation

**No speculative changes.** A change motivated by "might fix" or "should help" rather than a compiler error or a failing test requires explicit justification in the Stage 1 proposal.

Evidence hierarchy (highest to lowest confidence):

1. GHC compiler error with a stack trace
2. Failing test with an assertion message
3. `rg` result showing actual usage
4. Reading the file that contains the relevant code

**Triangulation for parser constructs.** Every new parser needs at least three test shapes:

- Positive: valid input → expected AST
- Negative: invalid input → parse failure (not a crash)
- Property: at least one Hedgehog invariant

---

## Testing Discipline

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

**Table-driven tests.** When 3+ test cases share the same assertion shape, use a list and `mapM_` or a helper — do not repeat identical structure.

**No external snapshot files.** Inline expected values in assertions. Use a locally-defined `Text` literal for multi-line output. Longer term we may loosen this requirement. Make a recommendation if unsure.

**Megaparsec exploration.** Use `parseTest` from `Text.Megaparsec` in the REPL to get human-readable failure output. In tests, use `parse` with `assertBool`/`assertEqual` and a descriptive message.

**Structuring.** Keep test files short and have a master test runner in `test/Main.hs` that imports and aggregates them. Keep PBT and unit tests separate. Don't refer to "phase numbers" or anything like that which has temporal implications, just give everything logical names.

**Runtime test pattern (Plan 107).** When testing the PB interpreter / runtime reducer, use
`MockRuntimeEnv` for controlled SQL responses and `renderWindow()` for logical JSX output.
Never start the server or hit a real database in unit tests.

```ts
import { createMockRuntimeEnv } from "../mock-runtime-env.js";
import { renderWindow } from "../../src/core/render-window.js";

// 1. Create mock env with controlled data
const mockEnv = createMockRuntimeEnv({
  misth_zpkrat: {
    rows: [{ kodkrat: "01" }],
    rowcount: 1,
    columns: ["kodkrat"],
  },
});

// 2. Set up store with mock env
const ts = createTestStore(runtimeReducer, mockEnv, initialRuntimeState);

// 3. Load AST and run event
ts.send({ tag: "set-ast", ast });
ts.send({ tag: "run-event", owner: "w_test", event: "open" });
ts.receive({ tag: "sql-result", dwName: "dw", rows: MOCK_ROWS });

// 4. Assert on state
expect(ts.getState().controlValues["dw"]).toHaveLength(1);

// 5. Render and assert on logical structure
const rendered = renderWindow(
  ast,
  ts.getState().controlValues,
  ts.getState().variables,
);
expect(rendered.dataWindows[0]!.rows).toHaveLength(1);
```

**Backend SQL mock mode.** Set `PB_SQL_MOCK=1` to return canned data instead of connecting
to MySQL. Useful for development iteration without a running database:

```bash
PB_SQL_MOCK=1 cd cli && uv run pb explore   # mock mode
uv run pb explore                            # live mode (default)
```

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

---

## UI Architecture Rules (TypeScript / SolidJS)

These rules apply to all work under `ui/`. Violating them causes `ECONNREFUSED` noise in
tests, forces `vi.stubGlobal` hacks, and breaks the type-safety the architecture is built around.

### Rule 1 — No component calls `fetch`

**All HTTP calls flow exclusively through `AppEnv` methods.** Components never call `fetch`.
If a component needs server data, the sequence is always:

```
user action → store.dispatch(action) → reducer → env.method() → Effect → dispatch(result-action) → state update → component re-renders
```

Calling `fetch` inside a component (in `onMount`, `createResource`, a signal setter, etc.)
is always wrong. It bypasses the env, makes the behavior untestable without `vi.stubGlobal`,
and fires an actual HTTP request against a non-running server in tests — causing `ECONNREFUSED`.

**Wrong:**

```tsx
function MyComponent() {
  const [data, setData] = createSignal(null);
  onMount(async () => {
    const r = await fetch("/api/my-endpoint"); // ❌
    setData(await r.json());
  });
}
```

**Right:** the reducer fetches via `env`; the component reads from the store snapshot.

### Rule 2 — Adding a new API call: the six-step checklist

Follow all six steps every time. Missing any one causes TypeScript errors or test noise.

1. **Feature `Env` interface** — add the typed method:

   ```ts
   // e.g., in features/datawindows/reducer.ts
   export interface DatawindowsEnv {
     getDwLayout(name: string): Effect<DataWindowFile>;
   }
   ```

2. **`ApiClient` interface + implementation** — in `ui/src/features/app/api-client.ts`:

   ```ts
   // interface:
   getDwLayout(name: string): Promise<DataWindowFile>;
   // implementation:
   async getDwLayout(name: string): Promise<DataWindowFile> {
     return fetchJson("/api/objects/" + encodeURIComponent(name) + "/dw");
   }
   ```

3. **`createEnv` wiring** — in the same `api-client.ts` `createEnv` function:

   ```ts
   getDwLayout: (n) => lift(() => api.getDwLayout(n)),
   ```

4. **`mockEnv` in `ui/tests/helpers.tsx`** — add a no-op entry:

   ```ts
   getDwLayout: () => Effect.none(),
   ```

5. **Feature-local mock envs** — any test file with its own `const mockEnv: FeatureEnv` must
   also add the method. Search for files that declare the feature's `Env` type explicitly:

   ```bash
   rg -l "DatawindowsEnv\|ExploreEnv" ui/tests/
   ```

6. **Reducer usage** — return `Effect.merge` when firing in parallel with another call:

   ```ts
   case "select":
     return Effect.merge(
       env.getDW(action.name).map(...).catch(...),
       env.getDwLayout(action.name).map(...).catch(...),
     );
   ```

### Rule 3 — Navigation via `env.navigate()`, never dispatched directly

Feature reducers call `env.navigate(navAction)` to change the route. They never return a nav
action as an `Effect` themselves.

`pullbackWithNav` (in `ui/src/core/reducer.ts`) intercepts `env.navigate` calls synchronously,
converts them to `Effect.send(widenNav(nav))`, and merges them with the feature's own effect.
Navigation fires in the same dispatch cycle. See `doc/nav-philosophy.md` for full rationale.

**Wrong:**

```ts
case "select":
  // ❌ Feature should not know about app-level action shape
  return Effect.send({ tag: "nav", action: { tag: "navigate", route: { view: "dwDetail", name } } });
```

**Right:**

```ts
case "select":
  draft.dwDetail = null;
  env.navigate({ tag: "navigate", route: { view: "dwDetail", name: action.name } });
  return env.getDW(action.name).map((data): MyAction => ({ tag: "detail-loaded", data }));
```

`navigate` must be declared in the feature's `Env` interface as
`navigate(action: NavigationAction): Effect<never>`. `pullbackWithNav` provides the
implementation at the app level — the feature never calls `history.pushState` or touches the
nav reducer directly.

### Rule 4 — Test injection via closures, never `vi.stubGlobal`

**`vi.stubGlobal("fetch", ...)` is always wrong.** Use env closure injection instead.

`mockEnv` in `ui/tests/helpers.tsx` returns `Effect.none()` for every method — no real HTTP
requests are ever made when using `createTestStore`. To test a code path that fires a specific
env method, override that method with a closure:

**Reducer / TCA-style test (for logic testing):**

```ts
const env: DatawindowsEnv = {
  ...mockEnv,
  getDwLayout: () => Effect.send(MOCK_DW_FILE),
};
const ts = createTestStore(datawindowsReducer, env, initialDatawindowsState);
ts.send({ tag: "select", name: "my_dw" }, (s) => {
  s.dwDetail = null;
  s.dwLayout = null;
});
ts.receive({ tag: "layout-loaded", data: MOCK_DW_FILE }, (s) => {
  s.dwLayout = MOCK_DW_FILE;
});
```

**Component test (for rendering testing):** pre-populate state; no env override needed:

```ts
const { store } = createTestStore({
  datawindows: { ...initialDatawindowsState, dwLayout: MOCK_DW_FILE, dwDetail: makeDw() },
});
render(() => <DWDetail store={store} />);
expect(document.querySelector(".dw-preview")?.textContent).toContain("header");
```

### Rule 5 — `Effect` quick reference

```ts
Effect.none()              // does nothing — use in mock env stubs
Effect.send(value)         // dispatches value synchronously — use in tests
Effect.fromPromise(fn)     // calls fn(), dispatches resolved value — use for real API calls
Effect.merge(e1, e2, ...)  // runs all in parallel, same dispatch channel
eff.map(f)                 // transforms the dispatched value
eff.catch(onReject)        // converts rejection to a dispatched action (never let effects throw)
```

Reducers return `Effect<ActionType> | null`. The store's `dispatch` calls `effect.execute(dispatch)`.
Never start async work inside a reducer body — only inside `env` method implementations.

### Diagnosing test-time `ECONNREFUSED` errors

If `pnpm test` shows `ECONNREFUSED` in stderr (not a test failure — console noise), the cause
is always a component making a real `fetch` call. The fix is never `vi.stubGlobal`; it is
always one of:

- The component is calling `fetch` directly → move the call into an `AppEnv` method (Plan 104).
- A new env method was added but not to `mockEnv` in `helpers.tsx` → add `Method: () => Effect.none()`.
- A feature test file has its own `mockEnv` that is missing the new method → add it there too.

---

## Reference Docs

The parser specification is in `doc/spec.md` — consult it first for any question about lexical rules, token forms, file structure, or DataWindow syntax. It is synthesized from the battle-tested reference implementation and amended with corrections from the official Appeon docs.

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

| Module          | Purpose                                                                                                                             |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `PB.AST.*`      | Data types only — no parsing logic (Located, Expr, BodyStmt, Type, SourceFile, DataWindow)                                          |
| `PB.Lexing.*`   | Tokenization, layout, string mode                                                                                                   |
| `PB.Grammar.*`  | megaparsec parsers (Body, File, Stream, DataWindow)                                                                                 |
| `PB.Pipeline.*` | Multi-step transformations: Preprocess, Emit, Passes, Runner, Serialise, FileWalk, DuckDb, SqlParse, Church                        |
| `PB.Analysis.*` | Pure analysis passes: Cfg, InstrGraph, Dataflow, DeadCode, Taint, TypeEnv, TypeResolve, Builtins                                      |
| `PB.Prelude`    | Custom Prelude — no parsing or transformation logic                                                                                 |

New modules go in the most specific matching directory. If a new layer is needed, propose it in Stage 1.

---

## Code Index

Maintained here to avoid re-scanning the tree. **Update when exports change.**
Verified against source on 2026-06-21 — if you edit a constructor and don't
update the matching entry here, the next session re-derives it the hard way
(this cost real time in the 111a session). Field names below are the raw
Haskell record names; the Aeson wire shape renames them via `stripCamelCasePrefix`
(see Stage 0 notes) — e.g. `callArgs` serialises as `args`, `lvSegments` as
`segments`.

### `PB.AST.Located`

```haskell
data Located a = Located
  { locLine :: Int   -- source start line (llStartLine of the originating LogicalLine)
  , locNode :: a
  } deriving (Eq, Show, Generic)
```

### `PB.AST.Expr`

```haskell
-- Field names are unprefixed (record-dot disambiguation under
-- DuplicateRecordFields). Token lists are [Text], NOT [Token].
data LvSegment = LvSegment { name :: Text, subscript :: Maybe [Text] }
newtype Lvalue = Lvalue { segments :: [LvSegment] }   -- non-empty

data BinOp
  = BopAdd | BopSub | BopMul | BopDiv | BopPow
  | BopEq  | BopNe  | BopLt  | BopGt  | BopLe | BopGe
  | BopAnd | BopOr  | BopXor

data DispatchMode = DmPost | DmTrigger | DmSync
data DispatchExpr = DispatchExpr
  { object :: Maybe Lvalue, mode :: DispatchMode, dynamic :: Bool
  , event :: Bool, name :: Text, args :: [[Token]] }

data Expr
  = ExBool       Bool             | ExInt Text  | ExReal Text
  | ExStr        Text             | ExDate Text | ExTime Text | ExNull
  | ExEnum       Text             -- enum constant (without trailing '!')
  | ExLvalue     Lvalue           -- bare ident / member chain / subscript
  | ExCall       { callee :: Lvalue, callArgs :: [[Token]] }
  | ExMethodCall { receiver :: Expr, method :: Text, methodArgs :: [[Token]] }
  | ExDispatch   DispatchExpr     -- POST/TRIGGER/DYNAMIC/EVENT dispatch
  | ExCreate     Text             -- CREATE ClassName
  | ExCreateUsing Expr            -- CREATE USING expr
  | ExArray      [Expr]
  | ExBinOp      { lhs :: Expr, op :: BinOp, rhs :: Expr }
  | ExNot        Expr
  | ExNeg        Expr             -- unary minus
  | ExHostVar    Lvalue           -- SQL host variable :varname
  | ExRaw        [Text]           -- SQL fragments / unrecognised
  -- NOTE: there is no ExLit / Literal type — literals are split across
  -- ExBool/ExInt/ExReal/ExStr/ExDate/ExTime/ExNull. Old index entries that
  -- referenced Literal/CallExpr/CreateExpr/ExUnaryMinus were stale.
```

### `PB.AST.BodyStmt`

```haskell
data AugOp = AugAdd | AugSub | AugMul | AugDiv

-- PB CALL statement: CALL ancestorobject [`controlname] :: event
data PbCall = PbCall { pbcAncestor :: Text, pbcEvent :: Text }

-- One elseif branch. ifElseIfs is [ElseIf], NOT [(Expr, [Located BodyStmt])].
data ElseIf = ElseIf { eifCond :: Expr, eifBody :: [Located BodyStmt] }

data IfStmt = IfStmt
  { ifCond :: Expr, ifThen :: [Located BodyStmt]
  , ifElseIfs :: [ElseIf], ifElse :: Maybe [Located BodyStmt] }

data ForStmt = ForStmt
  { forVar :: Lvalue, forFrom :: Expr, forTo :: Expr
  , forStep :: Maybe Expr, forBody :: [Located BodyStmt] }

data DoCondition = DoWhile Expr | DoUntil Expr

data DoStmt = DoStmt
  { doCond :: Maybe DoCondition, doBody :: [Located BodyStmt]
  , doLoop :: Maybe DoCondition }

data CaseClause = CaseClause
  { ccExpr :: Maybe [Token]   -- Nothing = "case else"
  , ccBody :: [Located BodyStmt] }

data ChooseStmt = ChooseStmt
  { chooseExpr :: Expr, chooseClauses :: [CaseClause] }

data BodyStmt
  = BsLocalVar  { varMods :: [Text], varType :: PbType, varName :: Text, varInit :: Maybe Expr }
  | BsAssign    Lvalue Expr           -- lhs = rhs
  | BsAugAssign [Token] AugOp [Token]   -- lhs_tokens op= rhs_tokens
  | BsInc       [Token]                -- lhs_tokens ++
  | BsDec       [Token]                -- lhs_tokens --
  | BsCall      Expr                  -- standalone call expression
  | BsPbCall    PbCall                -- CALL ancestor[`ctrl] :: event
  | BsReturn    (Maybe Expr)          -- return [expr]
  | BsIf        IfStmt
  | BsFor       ForStmt
  | BsDo        DoStmt
  | BsChoose    ChooseStmt
  | BsExit
  | BsContinue
  | BsDestroy   Lvalue                -- DESTROY objectvariable
  | BsAssignExpr Expr Expr            -- complex LHS = rhs (method-call chain . property)
  | BsTry       TryStmt
  | BsThrow     Expr
  | BsRaw       Text                  -- SQL, event decls, unclassified (source text)

-- | catch (ExceptionType varName) clause
data CatchClause = CatchClause { catchExnType :: Text, catchExnVar :: Text, catchBody :: [Located BodyStmt] }
-- | try … catch … end try
data TryStmt = TryStmt { tryBody :: [Located BodyStmt], tryCatches :: [CatchClause] }

  -- PbType comes from PB.AST.Type: PtPrimitive Text | PtUserDefined Text
  --   | PtAny | PtDecimalPrec Int. No IsString instance — always wrap as
  --   PtPrimitive "integer" etc. (the 111a test was wrong about this.)
```

### `PB.AST.Type`

```haskell
data PbType
  = PtPrimitive Text | PtUserDefined Text | PtAny | PtDecimalPrec Int
renderPbType :: PbType -> Text
parseTypeText :: Text -> PbType          -- inverse, used by TypeResolve/TypeEnv
-- No IsString instance. primitiveNames list in-module.
```

### `PB.AST.DataWindow` / `PB.Grammar.DataWindow`

Partial entry — only the fields/functions touched by Plan 163 Phase 1
(2026-07-10). The rest of these modules' types (`DwBand`/`DwGroup`/
`DwColumn`/`DwTable`/`DwControl`/etc, and their parsers) are not yet
indexed here.

```haskell
-- PB.AST.DataWindow
data DwWhereClause = DwWhereClause
  { dwcExp1, dwcOp, dwcExp2 :: Text, dwcLogic :: Maybe Text
  , dwcParsedExp1, dwcParsedExp2 :: Maybe Expr }  -- Plan 163 Phase 1 (D2)
-- Mirrors DwControl's dwcParsedExpression/dwcParsedFormat naming/pipeline.
-- 33/187 real corpus rows (openpay) carry a surplus leading '(' on EXP1
-- and/or trailing ')' on EXP2 -- PowerBuilder's own WHERE-grid grouping
-- parens, spliced onto whichever row sits at a visual group's boundary
-- (see doc/spec.md 7.3 "WHERE-clause grouping-paren leakage"; confirmed
-- NOT a powerbuilder-pbl-dump bug -- that tool does a verbatim byte
-- extraction, see doc/pbl.md's "Data chain" note). Fixed 2026-07-10:
-- parseWhereOperand strips the surplus via stripSurplusParens before
-- parsing, so dwcParsedExp1/2 resolve normally even on group-boundary
-- rows; dwcExp1/dwcExp2 (raw) stay verbatim, unaffected.

-- PB.Grammar.DataWindow
parseWhereOperand :: Text -> Maybe Expr
-- Not exported. stripSurplusParens . tokenizeExpr . parseExpr pipeline
-- (same tokenizeExpr/parseExpr DwControl's expression/format fields use,
-- plus the paren-leakage strip); top-level ExRaw result -> Nothing.
stripSurplusParens :: Text -> Text
-- Not exported. Strips a leading run of '(' from EXP1 (or trailing run of
-- ')' from EXP2) only while the text's own net paren balance is nonzero --
-- an already-balanced parenthesized sub-expression (real function call,
-- `(a+b)`) is left untouched. Deliberately local/per-field: does not (and
-- doesn't need to) reconstruct true cross-row group nesting -- verified
-- empirically (zero anomalies across all 33 affected corpus rows) that the
-- surplus is always a pure leading/trailing run, never interior or
-- cross-contaminated between EXP1/EXP2.
```

### `PB.Grammar.Body`

```haskell
classifyBodyStmt :: Statement -> BodyStmt          -- leaf classifier; exit/continue/return/var/assign
parseBodyStmts   :: [Statement] -> [Located BodyStmt]  -- flat map; uses llStartLine for locLine
parseLvalue      :: [Token] -> Maybe Lvalue
parseExpr        :: [Token] -> Expr   -- total; ExRaw fallback; TkColon guard for SQL host vars
pBodyStmt        :: FileParser (Located BodyStmt)  -- captures currentLine before dispatching
-- Internal helpers (not exported): parseAtom, climbPrec, chainCalls, etc.
```

### `PB.Pipeline.Preprocess`

```haskell
normalizeText :: Text -> [LogicalLine]
stripHeaders  :: [LogicalLine] -> ([Text], [LogicalLine])

data LogicalLine = LogicalLine
  { llText      :: Text
  , llStartLine :: Int
  , llEndLine   :: Int
  }
```

### `PB.AST.SourceFile`

```haskell
data SrFile = SrFile
  { srHeaders         :: [Text]
  , srForward         :: Maybe ForwardBlock
  , srPrototypes      :: Maybe PrototypesBlock
  , srVariables       :: Maybe VariablesBlock
  , srGlobalInstances :: [GlobalInstance]
  , srTypeBlocks      :: [TypeBlock]
  , srOnBlocks        :: [OnBlock]
  , srEvents          :: [EventBlock]
  , srFunctions       :: [FunctionBlock]
  , srSubroutines     :: [SubroutineBlock]
  }

data ForwardBlock    = ForwardBlock    { fwdTypes :: [TypeDecl], fwdInstances :: [GlobalInstance] }
data PrototypesBlock = PrototypesBlock { protoDecls :: [ProtoDecl] }
data ProtoDecl       = ProtoFn FnSig | ProtoSub SubSig | ProtoEv EventSig

data VariablesBlock = VariablesBlock { varScope :: VarScope, varDecls :: [VarDecl] }
data VarScope       = GlobalVars | TypeVars

data TypeDecl = TypeDecl { tdName :: Text, tdAncestor :: Text, tdWithin :: Maybe Text }
data TypeBlock = TypeBlock { tbDecl :: TypeDecl, tbBody :: [Located BodyStmt] }
data VarDecl   = VarDecl  { vdModifiers :: [Text], vdType :: Text, vdName :: Text }
data GlobalInstance = GlobalInstance { giType :: Text, giName :: Text }

data FnSig  = FnSig  { fnsMods :: [Text], fnsReturnType :: Text, fnsName :: Text, fnsParams :: Text, fnsThrows :: Maybe Text }
data SubSig = SubSig { ssMods  :: [Text], ssName :: Text, ssParams :: Text, ssThrows :: Maybe Text }
data EventSig = EventSig { esName :: Text, esRawSig :: Text }

data FunctionBlock   = FunctionBlock   { fbSig :: FnSig,   fbBody :: [Located BodyStmt] }
data SubroutineBlock = SubroutineBlock { sbSig :: SubSig,  sbBody :: [Located BodyStmt] }
data EventBlock      = EventBlock      { evSig :: EventSig, evOwner :: Maybe Text, evBody :: [Located BodyStmt] }
data OnBlock         = OnBlock         { obQualName :: Text, obOwner :: Text, obEvent :: Text, obBody :: [Located BodyStmt] }

srAllTypeDecls  :: SrFile -> [TypeDecl]           -- srTypeBlocks decls, then forward-only decls
srPrimaryObject :: SrFile -> (Text, Maybe Text)   -- (name, ancestor) of the file's own object
splitAncestorRef :: Text -> (Text, Maybe Text)
-- Plan 164 Phase A (2026-07-10). Splits PowerBuilder's "AncestorClass`LocalName"
-- control-override syntax (e.g. tdAncestor = "w_form_tab2`page1", meaning
-- "this local override of page1 is based on ancestor w_form_tab2's own
-- declaration of a control named page1"). The lexer treats backtick as an
-- identifier-continuation char (isIdentCont), so tdAncestor carries the whole
-- compound token verbatim with nothing splitting it apart before this.
-- (class, Nothing) when there's no backtick; splits at the first backtick
-- only. Consumed by TypeResolve.buildInheritsMap and TypeEnv.extractTypeDecls
-- (both build a name->ancestor map used for ancestor-chain walks -- without
-- this, a chain hits a backtick-declared node and silently stops, since no
-- object is ever literally named "w_form_tab2`page1") and by
-- Emit.extractWindowLayout's mkControl (replaced an ad hoc, Just-half-discarding
-- T.takeWhile (/= '`') that did the same job one-off, cosmetically, for the
-- rendered control "type" label).
-- srPrimaryObject (fixed Plan 163 Phase 3.5, 2026-07-10): prefers the
-- srTypeBlocks entry whose tdName matches the forward block's first
-- fwdTypes entry (PB's exporter always declares the file's own type first
-- in forward, ahead of nested control forwards) -- NOT simply "head of
-- srTypeBlocks". Falls back to head-of-srTypeBlocks, then forward's own
-- first entry, then ("", Nothing), when there's no forward block or no
-- name match. Needed because a top-level non-visual type block (e.g.
-- `type os_data from structure`) can be declared textually before the
-- file's real window/user-object block; every consumer keying off this
-- single per-file "obj" (Runner.hs's compileOne, Emit.hs's wrapSrFile,
-- Taint.hs's extractTaintInputs) was silently misattributing every
-- procedure/call-site/SetItem-binding-lookup in such files (11/433 files in
-- PowerBuilder-Example-extract, 0/139 in openpay -- see BACKLOG's closed
-- "Plan 163 Phase 3 wiring session" entry).
```

### `PB.Grammar.File`

```haskell
parseSrFile         :: [Text] -> [Statement] -> Either Text SrFile   -- no spans
parseSrFileWithSpans :: [Text] -> [Statement] -> Either Text (SrFile, SrSpans)  -- Runner uses this
-- SrSpans carries (startLine, endLine) per block; consumed by wrapSrFile for "meta".
pForwardBlock    :: FileParser ForwardBlock
pPrototypesBlock :: FileParser PrototypesBlock
pVariablesBlock  :: FileParser VariablesBlock
pGlobalInstance  :: FileParser GlobalInstance
pTypeDecl        :: FileParser TypeDecl
pVarDecl         :: FileParser VarDecl
pProtoDecl       :: FileParser ProtoDecl
pEndKw           :: Text -> FileParser ()
pTypeBlock       :: FileParser TypeBlock
pOnBlock         :: FileParser OnBlock
pEventBlock      :: FileParser EventBlock
pFunctionBlock   :: FileParser FunctionBlock
pSubroutineBlock :: FileParser SubroutineBlock
-- NOTE: the old pBodyUntil helper no longer exists (removed in the spans refactor).
```

### `PB.Grammar.Stream`

```haskell
newtype StmtStream = StmtStream [Statement]
type FileParser = Parsec Void StmtStream

satisfyStmt      :: (Statement -> Bool) -> FileParser Statement
leadingKind      :: TokenKind -> FileParser Statement
leadingText      :: Text -> FileParser Statement
isModifierToken  :: Token -> Bool   -- TkAccessModifier | TkStorageModifier
currentLine      :: FileParser Int  -- llStartLine of the next statement (without consuming)
```

### `PB.Pipeline.Emit`

```haskell
-- Single-file parsing, JSON wrapping, layout extraction.
runFile           :: FilePath -> Text -> Either Text Value
collectStatements :: [LexLine] -> Either Text [Statement]
wrapSrFile        :: Bool -> FilePath -> SrFile -> SrSpans -> TypeEnv -> Value
extractWindowLayout :: [TypeBlock] -> Maybe Value
reconstructRetrieveSql :: DwRetrieveOrRaw -> Text
fileKind          :: FilePath -> FileKind
data FileKind     = DataWindow | Pipeline | Project | PowerScript
data ParsedFile   = ParsedFile { pfPath :: FilePath, pfSrFile :: SrFile, pfSpans :: SrSpans, pfContents :: Text }
data ParseOutcome = PsParsed ParsedFile | PsDw FilePath Text DataWindowFile | PsFailed FilePath Text | OtherFile FilePath
parseOutcome      :: FilePath -> FilePath -> IO ParseOutcome
-- root -> src -> outcome (path relativization, 2026-07-09): every path in
-- the returned ParsedFile/PsDw/PsFailed/OtherFile is `makeRelative root src`,
-- not the raw absolute src used to actually read the file. This is the sole
-- choke point for ingested-path storage -- compileOne and every DB row
-- constructor just reads pfPath/the FilePath in the outcome verbatim, so
-- fixing it here fixes every stored/displayed path. Callers thread the
-- ingestion root (runModeDb's srcDir) down through workerLoopFiles/
-- workerLoopFilesNoBridge (see PB.Pipeline.Runner below).
stripBom          :: Text -> Text
```

### `PB.Pipeline.Passes`

```haskell
-- Phase B orchestration: link analysis (passes 5-11) in DuckDB mode.
runPhaseB :: DuckConn -> Maybe Text -> IO ()
-- 2nd param is mDefaultNamespace (Plan 157 Phase 1, 2026-07-09), threaded
-- through from Runner.runModeDb's --default-namespace flag into runPass9.
-- Internally: runPass5 (resolveTypes + resolveCalls → resolved_types/calls),
--             runPass67 (buildInterprocEdges + taint → interproc_edges/taint_*),
--             runPass8 (computeDeadProcedures → dead_code)
--             runPass9 (Plan 148 Phase 1b, 2026-07-07: queryDwRetrieveColumns/
--               queryDwJoinLegs/querySqlCols/queryCatFootprintColumns (Plan 163
--               Phase 3, 2026-07-10)/queryDwWriteColumns/queryDwWhereColumns
--               (Plan 163 Phase 6, 2026-07-10)/queryCatColumns/queryCatFks →
--               SchemaCategory.buildSchema → schema_objects/schema_morphisms;
--               now returns SchGraph, not (), so Pass 10 can traverse it
--               without rebuilding from DB rows. mDefaultNamespace (Plan 157
--               Phase 1) flows into SchemaInputs' inDefaultNamespace field.)
--             runPass10 (Plan 153 D5, 2026-07-07: columnCoslice over every
--               ColumnObj in the graph → decomposition_coslice)
--             runPass11 (Plan 161, 2026-07-11; Souffle backend since same
--               day's Phase 0 reversal: materializes
--               PB.Pipeline.Souffle's reachesRules/liveProcRules programs →
--               reaches/live_proc tables. Uses Souffle.runRuleSetWith's
--               per-relation progress callback, not the plain runRuleSet --
--               emits one "step" event per relation so the CLI reporter
--               doesn't show one silent blanket step for the whole pass;
--               see PB.Pipeline.Souffle's own entry for why.)
runPass9  :: DuckConn -> Maybe Text -> IO SchGraph
runPass10 :: DuckConn -> SchGraph -> IO ()
runPass11 :: DuckConn -> IO ()
```

### `PB.Pipeline.Souffle` (Plan 161, Souffle migration done 2026-07-11 -- replaces the deleted `PB.Pipeline.Datalog`)

```haskell
-- Pure IR + a Souffle-CLI backend for the reaches-style whole-program
-- queries Plan 161 exists to replace bespoke Haskell traversals with.
-- Phase 0's original DuckDB-native decision was reversed same-day (see the
-- plan's "Phase 0 -- reopened" section): a Homebrew packaging bug wrongly
-- disqualified Souffle's compiled mode, and a re-measure with it included
-- showed Souffle beating DuckDB-native; a realistic aggregate rule (caller
-- fan-in count) had no home in the old IR's plain-SELECT compiler at all.
-- Same IR as before: EDB relations (leg/dead/stmt) are VIEWS over existing
-- tables (initEdbViews) -- no fact-marshalling round trip through DuckDB
-- itself, though facts DO now round-trip through Haskell once, out to
-- Souffle's .facts files and back from its .csv output (unlike the old
-- module, which stayed inside DuckDB via WITH RECURSIVE the whole time).
data Relation = Relation { relName :: Text, relCols :: [Text] }
-- litArgs are variable names or the wildcard "_", positionally aligned to
-- relCols of litRelation (same arity -- mismatched lengths = malformed Rule).
data Literal  = Literal { litRelation :: Relation, litArgs :: [Text], litNegated :: Bool }
data Rule     = Rule { ruleHead :: Literal, ruleBody :: [Literal] }        -- ruleHead's litNegated always False
data RuleSet  = RuleSet { rsRelations :: [Relation], rsRules :: [Rule] }   -- a relation may have several alternative rules, unioned

edbRelations :: RuleSet -> [Relation]
-- Every relation referenced in any rule's head/body that is NOT in
-- rsRelations (the derived/IDB set) -- these are the EDB relations the
-- program assumes are already populated. Souffle hard-errors on a missing
-- .facts file for a declared .input relation, so every one of these gets a
-- file written, even an empty one.

compileProgram :: RuleSet -> Text
-- Renders a full Souffle .dl program: .decl+.input per EDB relation
-- (edbRelations), .decl+.output+translated rules per IDB relation
-- (rsRelations). Every column is declared `symbol` (Souffle's string type)
-- -- every value this project currently feeds through (schema keys, kinds,
-- object names) is already string-shaped. Souffle stratifies and evaluates
-- the whole program itself -- no ordering step is needed from the caller
-- (the old module's stratify/topoSort/compileRelation/compileBody/
-- compileRule/lookupBound are GONE; there is nothing left at the Haskell
-- level for them to do).

runRuleSet     :: DuckConn -> RuleSet -> IO ()
runRuleSetWith :: (Relation -> IO ()) -> DuckConn -> RuleSet -> IO ()
-- runRuleSet = runRuleSetWith (\_ -> pure ()). Per call: withSystemTempDirectory
-- (temporary pkg) -> for each edbRelations member, PB.Pipeline.DuckDb.queryTextRows
-- reads its current rows and writes a tab-separated <name>.facts file (always
-- written, even with zero rows) -> compileProgram's output written to a .dl
-- file -> `souffle -F factsDir -D outDir program.dl` via readProcessWithExitCode
-- (interpreted mode; a non-zero exit is a hard `error`, same tier as the old
-- module's unstratifiable-ruleset error) -> for each rsRelations member, calls
-- onRelation (PB.Pipeline.Passes' runPass11 wires this to emitProgress, one
-- "step" event per relation, e.g. "Datalog: reaches", same reason as before:
-- the CLI reporter's Phase B view shows only the latest step label with no
-- sub-progress bar), reads back its <name>.csv output, then
-- PB.Pipeline.DuckDb.recreateTextTable + appendTextRows materializes it as a
-- DuckDB table (drop + create all-TEXT columns, generic-arity append -- see
-- that module's own entry). Any future, larger Phase 3 rule set MUST use
-- runRuleSetWith, not bare runRuleSet, for the same reason as before.

initEdbViews :: DuckConn -> IO ()
-- (Re)creates leg (from schema_morphisms), dead (from dead_code), and stmt
-- (from schema_objects) as views. stmt is filtered to kind = 'stmt' ONLY --
-- excluding kind = 'dw_retrieve' rows is deliberate: a DwRetrieveId
-- StmtObj's stmt_proc is always NULL, and dead_code only keys on real
-- (object, proc_name) pairs, so a NULL proc vacuously passes `NOT EXISTS
-- dead` -- every DW retrieve would otherwise pollute live_proc as
-- unconditionally "live" (found via a real openpay --db smoke run: 114/115
-- stmt rows were this noise before the fix).

reachesRules  :: RuleSet
-- reaches(X,Y) :- leg(X,Y,_).  reaches(X,Z) :- reaches(X,Y), leg(Y,Z,_).
-- The Phase 0-validated port of SchemaCategory.blastRadius/
-- validationWalkBack's existence-only core (both functions' reachable set
-- reprojects off this one relation, either direction). Materializes to
-- table "reaches". Souffle handles the self-recursion natively -- no
-- WITH RECURSIVE translation needed on this side.
liveProcRules :: RuleSet
-- live_proc(Object,Proc) :- stmt(_,Object,Proc,_), !dead(Object,Proc).
-- Real stratified-negation demonstration (Plan 161 Open Question 4):
-- dead_code is fully computed (Pass 8) before Pass 11 ever runs, so no
-- cross-run ordering is needed here -- Souffle only has to confirm
-- live_proc isn't negatively self-referential (it is not). Materializes to
-- table "live_proc".
```

### `PB.Pipeline.SqlParse`

```haskell
-- Python sqlglot bridge: per-worker subprocess pool over a length-prefixed
-- JSON stdin/stdout protocol (sql_worker.py). ColumnRef/RowFilter (Plan 148
-- Phase 1a-2) are SqlResult's per-statement, scope-qualified column
-- attribution. TableRef/CatalogTable/CatalogPrimaryKey/CatalogForeignKey/
-- SchemaCatalog (Plan 148 Phase 1a-3, 2026-07-07) are the static DDL
-- catalog shape -- row-oriented (list, not Map TableRef [Text]) to match
-- the JSON wire format and DuckDb's row-oriented appenders directly.
-- PB.Analysis.SchemaCategory (Phase 1b, 2026-07-07) does NOT consume this
-- type directly -- it takes catalog_columns/catalog_fks rows queried back
-- from DuckDb (CatColumnRow/CatFkRow, its own read-shape types) instead,
-- keeping PB.Analysis.* free of any duckdb-ffi dependency.
--
-- Oracle DDL hardening (2026-07-08): SchemaCatalog gained scChecks
-- (CatalogCheckConstraint -- named CHECK predicates, sqlglot's normalized-SQL
-- rendering, not a re-parsed expression AST). SqlBridgePool gained
-- sbpDialect :: Text, set once at pool construction and used by BOTH
-- sendReceive (regular SQL) and parseDdl (DDL) -- previously DDL parsing
-- hardcoded "mysql" while SQL parsing hardcoded "oracle", a silent drift
-- that zeroed catalog_columns/catalog_pks for any non-MySQL corpus. parseDdl
-- now returns the full DdlResponse envelope (catalog + stats + parse_ok +
-- error), not just SchemaCatalog -- Runner.hs surfaces this via emitProgress
-- so a silently-empty catalog can never again go unreported. parseDdl also
-- takes a Maybe Text default-namespace (fills in the schema for a table/FK
-- reference left unqualified in the DDL text -- the common per-schema-dump
-- export convention); sql_worker.py's parse_ddl uses error_level=WARN and
-- strips Oracle's ENABLE/DISABLE/VALIDATE/NOVALIDATE/USING INDEX
-- constraint-state tail before parsing (sqlglot's grammar doesn't model it,
-- and one occurrence anywhere in a CREATE TABLE poisons the whole
-- statement otherwise) -- see cli/lib/src/pb/lib/ddl.py's module docstring.
data ColumnRef = ColumnRef { crNamespace, crTable :: Maybe Text, crColumn :: Text, crIsWrite :: Bool }
data RowFilter = RowFilter { rfNamespace, rfTable :: Maybe Text, rfColumn, rfOp :: Text, rfValues :: [Text] }
data SqlResult = SqlResult { srTables, srColumns :: [Text], srOperation :: Maybe Text
                            , srParseOk :: Bool, srColumnRefs :: [ColumnRef], srRowFilters :: [RowFilter] }
data TableRef = TableRef { trNamespace :: Maybe Text, trTable :: Text }   -- Ord; lowercased upstream
data CatalogTable      = CatalogTable      { ctRef  :: TableRef, ctColumns  :: [Text] }
data CatalogPrimaryKey = CatalogPrimaryKey { cpkRef :: TableRef, cpkColumns :: [Text] }
data CatalogForeignKey = CatalogForeignKey
  { cfkConstraintName :: Maybe Text
  , cfkFromTable :: TableRef, cfkFromColumns :: [Text]
  , cfkToTable   :: TableRef, cfkToColumns   :: [Text] }   -- from/to columns paired by position
data CatalogCheckConstraint = CatalogCheckConstraint
  { cckConstraintName :: Maybe Text, cckTable :: TableRef, cckPredicate :: Text }
data SchemaCatalog = SchemaCatalog
  { scTables :: [CatalogTable], scPrimaryKeys :: [CatalogPrimaryKey]
  , scForeignKeys :: [CatalogForeignKey], scChecks :: [CatalogCheckConstraint] }
data DdlStats = DdlStats { dsStatementsTotal, dsStatementsParsed, dsStatementsSkipped :: Int }
data DdlResponse = DdlResponse
  { ddlCatalog :: SchemaCatalog, ddlStats :: DdlStats, ddlParseOk :: Bool, ddlError :: Maybe Text }
data SqlBridgePool = SqlBridgePool
  { sbpSlots :: Vector (IORef WorkerConn), sbpCmd :: FilePath, sbpArgs :: [String], sbpDialect :: Text }
-- sbpCmd/sbpArgs (SQL bridge discovery hardening, 2026-07-09; was sbpBinary,
-- always exec'd with no args): startWorker now execs `cmd args` directly
-- (no shell). Production (PB.Pipeline.Runner) sets cmd = the python
-- interpreter path from --sql-worker-python (always sys.executable from the
-- pb CLI, never absent) and args = sqlWorkerModuleArgs = ["-m",
-- "pb.pipeline.bridge.sql_worker"] -- the worker module's location within
-- its own distribution is fixed and needs no discovery (formerly execed an
-- *installed pb-sql-worker console-script shim* directly, which depended on
-- that shim existing at all -- removed). Tests (SqlParseTest.hs/
-- RunnerTest.hs) pass a directly-executable shebang'd mock-worker script as
-- cmd with args = [] to substitute fake worker behavior (crash-on-Nth-
-- request, wrong protocol, etc) -- unchanged from before this rename.
sqlWorkerModuleArgs :: [String]  -- = ["-m", "pb.pipeline.bridge.sql_worker"]; exported constant
startSqlBridgePool  :: Int -> FilePath -> [String] -> Text -> IO SqlBridgePool   -- n, cmd, args, dialect (shared by parseSql + parseDdl)
shutdownSqlBridgePool :: SqlBridgePool -> IO ()
parseSql :: SqlBridgePool -> Int -> Text -> IO SqlResult          -- per-statement, any slot; retries once on worker crash
parseDdl :: SqlBridgePool -> Maybe Text -> Text -> IO DdlResponse -- pool, defaultNamespace, ddlText; always slot 0 (one-shot per run)
extractBsRawNodes :: [Located BodyStmt] -> [(Int, Text)]          -- recurses into if/for/do/choose bodies
-- Internal: requestResponse (shared framing, both parseSql/parseDdl go through it), encodeLen/decodeLen (4-byte BE length prefix)
```

### `PB.Pipeline.Runner`

```haskell
-- Batch orchestration: DuckDB streaming, worker loops.
-- Re-exports from Emit: runFile, collectStatements, wrapSrFile, extractWindowLayout, reconstructRetrieveSql
runModeDb :: FilePath -> FilePath -> [Text] -> Text -> Maybe FilePath -> Maybe Text -> IO ()
-- srcDir, dbPath, ddlArgs, dialect, mSqlWorkerFlag (Plan 148 Phase 1a-3; Oracle
-- hardening 2026-07-08 changed the DDL param from Maybe FilePath to [Text] and
-- added the dialect param). ddlArgs are raw --ddl CLI values in [schema:]path
-- form (repeatable -- e.g. --ddl CLIMS:clims.sql --ddl CLIMS_COMMON:common.sql
-- for multiple per-schema dumps with cross-schema FKs). dialect is the sqlglot
-- dialect for BOTH DDL and regular embedded-SQL parsing, set once on the
-- SqlBridgePool (see SqlParse's sbpDialect) so the two can't drift --
-- previously DDL silently hardcoded "mysql" while SQL parsing hardcoded
-- "oracle", which zeroed catalog_columns/catalog_pks for any non-MySQL
-- corpus. mSqlWorkerFlag (SQL bridge discovery hardening, 2026-07-09; final
-- form after 3 rounds -- see BACKLOG's retrospective) is a python
-- interpreter path passed explicitly via --sql-worker-python; preferred over
-- lookupEnv "PB_SQL_WORKER" (used only when the flag is Nothing, for
-- direct/manual `cabal run pbc --` invocations) so bridge availability can't
-- be lost anywhere in a shell -> uv run -> python -> subprocess.Popen chain.
-- The pb CLI always passes its own sys.executable here unconditionally --
-- never absent for a running interpreter, so there is no discovery/lookup
-- on the Python side at all. The bridge worker itself is then launched as
-- `pythonExe -m pb.pipeline.bridge.sql_worker` (SqlParse.sqlWorkerModuleArgs)
-- rather than exec'ing an installed pb-sql-worker console-script shim --
-- the checked-in module's location within its own distribution is fixed
-- and needs no separate discovery step either. When the bridge is
-- available, each ddlArg is read + parsed independently (parseDdlArg splits
-- the schema tag, parseDdl applies it as the default namespace for
-- unqualified tables/FK refs in that file) and appended via catalogToRows;
-- an emitProgress "ddl_loaded" event reports per-file parse_ok/error/
-- statement-stats/table+pk+fk+check counts -- so a silently-empty catalog
-- (the original bug report) can never go unnoticed again. When no bridge,
-- emits a "warning" progress event per ddlArg and skips (no hard error).
-- Main.hs's --ddl/--sql-dialect/--sql-worker-python flags thread through
-- here. The final 'Maybe Text' param is --default-namespace (Plan 157;
-- Phase 0 threaded it this far as mDefaultNamespace, Phase 1 wires it
-- through runPhaseB/runPass9 into SchemaCategory.buildSchema, which
-- resolves an unqualified table ref to this namespace iff the DDL catalog
-- defines the table under it -- never guessed).
parseDdlArg :: Text -> (Maybe Text, FilePath)
-- Pure. Splits a --ddl CLI value in [schema:]path form -- the prefix before
-- the first ':' is treated as a schema tag only when it contains no '/' (so
-- a bare path with no tag, e.g. "../clims.sql", passes through untouched).
catalogToRows :: SchemaCatalog -> ([CatalogColumnRow], [CatalogPkRow], [CatalogFkRow], [CatalogCheckRow])
-- Pure. Flattens SqlParse's row-oriented SchemaCatalog into DuckDb's row
-- types, assigning positional ordinals; composite FKs pair
-- fromColumns[i]/toColumns[i] by position. 4th tuple element (checks) added
-- alongside SchemaCatalog's scChecks field, 2026-07-08.
-- Internal: CompiledPs, CompiledDw, CompiledFile, compileOne, appendToDb,
--           workerLoopFiles, workerLoopFilesNoBridge, emitProgress, jsonText
-- CompiledDw gained cdDwRetrieveColumns :: [DwRetrieveColumnRow] (Plan 148
-- Phase 1b, 2026-07-07): compileOne's PsDw branch splits each DwRetrieve's
-- drColumns via SchemaCategory.splitColumnRef.
--
-- compileOne gained a DwFootprintCtx param (Plan 163 Phase 6, 2026-07-10),
-- slotted right after mDefaultNamespace: compileOne :: Set.Set (Text, Text)
-- -> Maybe Text -> DwFootprintCtx -> WorkspaceEnv -> ControlIndex ->
-- Map.Map Text [(TableRef, Text)] -> Maybe (SqlBridgePool, Int) -> Text ->
-- ParseOutcome -> IO CompiledFile. Built once in runModeDb from the same
-- DDL catalog rows catTables is derived from (mkDwFootprintCtx catCols
-- mDefaultNamespace on the bridge path; mkDwFootprintCtx [] mDefaultNamespace
-- -- empty catalog -- on the no-bridge path, matching catTables there), then
-- threaded through workerLoopFiles/workerLoopFilesNoBridge the same way
-- wsEnv/controlIdx already are. The PsDw branch calls
-- PB.Analysis.DwFootprint.dwRetrieveFootprint dwfCtx fpT obj table and
-- keeps only its LegWrites/LegReads legs (pattern-matched directly off the
-- Set SchMorphism; LegRetrieve/LegFk are dropped -- see this module's own
-- CompiledDw fields below), producing 2 new CompiledDw fields:
-- cdDwWriteColumns, cdDwWhereColumns :: [DwRetrieveColumnRow], appended via
-- 2 new DuckDb functions appendDwWriteColumns/appendDwWhereColumns.
-- CompiledPs gained cpsCatFootprintColumns :: [SqlStmtColumnRow] (Plan 163
-- Phase 3, 2026-07-10). compileOne's type signature gained a 4th positional
-- param, globalDwColumns :: Map.Map Text [(TableRef, Text)] (every DW's
-- resolved retrieve columns, keyed by lowercased DW name) -- built once in
-- runModeDb from Phase A0's already-parsed PsDw outcomes via the new pure
-- helper dwRetrieveColRowsForFootprint (deliberately not shared with
-- compileOne's own PsDw-branch DW-column extraction, which builds the
-- DuckDb-side DwRetrieveColumnRow, not SchemaCategory's DwRetrieveColRow --
-- same write-side/read-shape split as SqlParse's row types). Per procedure,
-- compileOne builds a PB.Analysis.SchFootprint.FunctorCtx (fcStmtObj =
-- SqlStmtId fp obj pName sLine; fcControlBindings = controlBindings'
-- (Plan 164 Phase C, see below) and folds compileProcedureToCatOp through
-- foldSchFootprint; morphismToColRow (Runner.hs, not exported) converts
-- each resulting SchMorphism back into the same SqlColRow-shaped raw fact
-- inSqlColumns already uses (see SchemaCategory's SchemaInputs note above
-- for why -- namespace resolution must stay centralized in buildSchema, not
-- baked in here) as a SqlStmtColumnRow, appended via
-- appendCatFootprintColumns. workerLoopFiles/workerLoopFilesNoBridge both
-- gained the same globalDwColumns param, threaded through from runModeDb.
-- FIXED (Plan 163 Phase 3.5, 2026-07-10, see BACKLOG's now-closed "Plan 163
-- Phase 3 wiring session" entry): resolveSetItem matches on
-- (T.toLower obj, ctrl), and obj comes from srPrimaryObject -- previously
-- wrong for any file declaring a non-window type block (e.g. `type X from
-- structure`) before its real window/user-object type block (11/433 files
-- in PowerBuilder-Example-extract, 0/139 in openpay). srPrimaryObject now
-- prefers the srTypeBlocks entry matching the forward block's first
-- fwdTypes entry (see its own Code Index entry below); verified against
-- pbexamw1.pbl/w_dw_copy.srw that objects/procedures now attribute to
-- w_dw_copy (not os_data) and cat_footprint_columns went from 0 to 5 rows
-- across PowerBuilder-Example-extract (this 5-row count is PowerBuilder-
-- Example's real baseline -- Plan 164's plan file/BACKLOG previously
-- misremembered it as "7/7"; re-confirmed via git stash before Phase C's
-- own changes too). Openpay's separate 0/6 SetItem gap (runtime aliasing,
-- e.g. `ctrl = other.uo.dw`) is addressed by Plan 164 Phase C below;
-- Phase C's own real-corpus gate didn't fully materialize until Phase E's
-- ControlIndex key-qualification fix (see that note) -- both now confirmed
-- against the real corpus.
--
-- compileOne gained a ControlIndex param (Plan 164 Phase C, 2026-07-10),
-- threaded through workerLoopFiles/workerLoopFilesNoBridge from a
-- workspace-wide `controlIdx = buildControlIndex allParsedSrFiles` built
-- once in runModeDb (same input file set as wsEnv). Inside the PsParsed
-- branch, the zip logic that used to be inlined directly into procs's list
-- comprehension is now a shared `procSpecs` binding (used by both procs and
-- the new alias scan below -- no behavior change, just de-duplication).
-- `aliasBindings = Map.unions [PB.Analysis.SchFootprint.runtimeDwAliasBindings
-- controlIdx (weHierarchy wsEnv) obj procEnvWithLocals body | ... <- procSpecs]`
-- scans every procedure in the file (steLocal seeded per-procedure via
-- CallClassify.collectBodyLocals) for the runtime DW-alias-assignment
-- pattern and unions the results file-wide (the alias assignment and the
-- SetItem call site are commonly in different procedures -- confirmed
-- against the real w_misth_fylo_form.srw example). `controlBindings' =
-- Map.union controlBindings aliasBindings` (static literal bindings win on
-- a key collision) is what every procedure's FunctorCtx now uses instead of
-- the old file-static-only controlBindings. FIXED (Plan 164 Phase E,
-- 2026-07-10): controlIdx's own (owner, name) key used to collide across
-- unrelated windows reusing a common generic child-control name at
-- full-corpus scale, so this wiring's real openpay gate (2 new
-- cat_footprint_columns rows) didn't materialize even though the wiring
-- itself was correct (real-corpus-fixture-verified in isolation). Phase E
-- qualified ControlIndex's key to (root, owner, name) -- see
-- PB.Analysis.ControlHierarchy's own entry below -- and the gate now
-- reaches 2/2 rows against the real corpus.
-- Phase A: parse → compile → append to DuckDB (concurrent producer-consumer)
-- Phase B: delegates to PB.Pipeline.Passes.runPhaseB (takes the
-- mDefaultNamespace param, Plan 157 Phase 1)
--
-- Plan 144 Phase 5 Step 7 (2026-07-06): the old CpsCompile.compileProcedure
-- compiler and every diagnostic that compared it against
-- CatOp.compileProcedureViaCatOp were deleted once the swap (Step 6) was
-- verified equivalent — collectAllProcs, runModeDualCps ("--dual-cps"),
-- runModeDualTrace ("--dual-trace"), runInspect/runInspectOn ("--inspect"),
-- isRealDiff, traceMaxSteps, and the corresponding Main.hs flags no longer
-- exist. compileProcedureViaCatOp (now PB.Analysis.GraphBuilder, moved from
-- CatOp in the Plan 151 module split, 2026-07-06) is the sole compiler.
```

### `PB.Pipeline.Serialise`

```haskell
-- Orphan ToJSON instances for all PB.AST.* types and PB.Analysis.Taint types.
-- Import as: import PB.Pipeline.Serialise ()
-- Brings ToJSON instances into scope; exports nothing explicitly.
-- Sum-type discriminator: "tag" key (string); single-field payload → "contents".
-- InterprocEdge, ProcedureSummary, ProcSummaryReturnFlow use manual instances
-- to match Python snake_case keys (caller_object, callee_proc, etc.).
-- LowCat (Plan 149 Phase 1): manual instance -- every constructor delegates
-- to genericToJSON EXCEPT LTagged, which is hand-written to emit only
-- {"tag":"LTagged","blockId":..} with NO "contents" (the real payload lives
-- once in WiringPayload's "sharedBlocks", not inlined at every reference).
```

### `PB.Pipeline.CfgBuild`

```haskell
-- Pure. buildCfg :: [Located BodyStmt] -> Cfg. Mirrors cfg_builder.py.
```

Moved to `PB.Analysis.Cfg` (Plan 118 H1; renamed from `PB.Analysis.CfgBuild`
in Plan 151 Phase 2a, 2026-07-06 — noun module name matching `SSA.hs`'s own
precedent, no content change).

### `PB.Analysis.Cfg`

```haskell
-- Pure. buildCfg :: [Located BodyStmt] -> Cfg. Mirrors cfg_builder.py.
data CfgBlock = CfgBlock { cbId :: Text, cbStmts :: [Located BodyStmt], cbFirstLine :: Maybe Int, cbLastLine :: Maybe Int }
data CfgEdge  = CfgEdge  { ceSrc :: Text, ceDst :: Text, ceLabel :: Text }
data Cfg      = Cfg      { cfgEntry :: Text, cfgExits :: [Text], cfgBlocks :: [CfgBlock], cfgEdges :: [CfgEdge] }
-- Edge labels: "T"/"F" (branches), "" (fallthrough), "loop" (back-edge), "case:N".
```

### `PB.Analysis.CallClassify`

```haskell
-- Pure call classification, plus two small pure AST helpers (parseArgList,
-- collectBodyLocals) moved in from the old PB.Analysis.CpsCompile in Plan
-- 151 Phase 2b (2026-07-06) -- they have nothing to do with InstrGraph's own
-- type (renamed from CpsGraph in Plan 152) and were already imported
-- alongside it by every consumer.
-- Shared by the old (deleted) compiler and the current SSA→CatOp pipeline.
data CallKind = PureCall | SuspendCall
classifyExpr :: ScopedTypeEnv -> Expr -> CallKind
-- classifyExpr returns SuspendCall (no effect name baked in).
-- effectName is a separate function (takes pre-parsed [Expr] args).
-- ExCall branch (Plan 164 D4, 2026-07-10): a single segment checks
-- isBuiltinSuspendFn; 2+ segments splits into (all-but-last, last) via
-- resolveLvalueType/reverse (no partial head/init/last -- PB.Prelude hides
-- them) and classifies on the resolved head-chain's type + the last segment
-- as method name. Previously only exactly-2-segment chains (`dw_1.retrieve()`)
-- were handled; a real dotted-chain-then-call of 3+ segments (the ONLY shape
-- Grammar.Body's lvaluePrefix/chainCalls ever produces for e.g.
-- `tab1.page1.uo_epidom.dw.Retrieve()` -- it's always a flat ExCall, never
-- nested ExMethodCall) silently fell through to PureCall.
effectName :: Expr -> [Expr] -> Text
isBuiltinSuspendFn :: Text -> Bool
isTypedSuspend :: Map.Map Text Text -> Text -> Text -> Bool
resolveLvalueType :: ScopedTypeEnv -> Lvalue -> Maybe Text
-- Not exported. Shared by classifyExpr's ExCall branch and
-- resolveReceiverType's ExLvalue branch (Plan 164 D4). 1 segment ->
-- lookupScopedVar; 2+ segments -> resolveMemberChainType (steControlIndex
-- env) (steHierarchy env) (steObject env) segs -- the workspace-wide
-- multi-hop control-chain resolver from PB.Analysis.ControlHierarchy.
resolveReceiverType :: ScopedTypeEnv -> Expr -> Maybe Text
-- ExLvalue branch now calls resolveLvalueType (multi-hop, was: first-segment
-- only). ExCall-as-receiver branch (a receiver that is itself a call, e.g.
-- `foo().bar()`) deliberately left single-segment-only -- that's call
-- return-type inference, a different unsolved problem, out of D4's scope.
calleeName :: Expr -> Text
segName :: LvSegment -> Text
lvHead :: Lvalue -> Text
isTriggerEvent :: Lvalue -> Bool
parseArgList      :: [Token] -> Expr                            -- imported by CatLower, CatEval
collectBodyLocals :: [Located BodyStmt] -> Map.Map Text PbType  -- imported by GraphBuilder
```

### `PB.Analysis.CatOp`

```haskell
-- Pure. The categorical IR only — typeclasses, GADT, instances. Plan 151
-- (2026-07-06) split the old 1367-line CatOp.hs (which had mixed 4 stages)
-- into this core module plus 3 siblings, each a single pipeline stage:
--   PB.Analysis.CatLower     -- SSA -> CatOp compilation (compileSsa)
--   PB.Analysis.GraphBuilder -- CatOp -> flat InstrGraph flattening,
--                            -- plus compileProcedureViaCatOp (the public
--                            -- one-call entry point Emit.hs/Runner.hs use)
--   PB.Analysis.CatInterp    -- direct Haskell execution (Interp/runCat)
class Category k where { id :: k a a; (.) :: k b c -> k a b -> k a c }
class Category k => Cartesian k where { exl, exr, (&&&) }
class Category k => Cocartesian k where { inl, inr, (|||) }
class Category k => Effectful k where { eval, assign, lookup, suspend, callProc, splitValue, ret, loopK }
-- ret/loopK added Plan 148 Phase 3 (2026-07-07): CatReturn/CatLoop were the
-- only 2 of CatOp's 20 constructors with no existing class primitive to
-- dispatch to (everything else, incl. CatAssignWithRhs = assign var . (id
-- &&& eval e), already reduced). CatOp's own instance: ret = CatReturn,
-- loopK = CatLoop. Interp's instance (PB.Analysis.CatInterp) absorbs the
-- old bespoke CatReturn/CatLoop cases (throwIO ReturnUnwind / interpretLoop).
branch  :: (Effectful k, Cartesian k, Cocartesian k) => Expr -> k env b -> k env b -> k env b
foldCat :: (Effectful k, Cartesian k, Cocartesian k) => CatOp a b -> k a b
-- foldCat (Plan 148 Phase 3): the fold CatOp is initial for, generalized to
-- any Effectful/Cartesian/Cocartesian instance -- not just Interp.
-- PB.Analysis.CatInterp.runCat is now `runCat = foldCat`. Second instance:
-- PB.Analysis.SchFootprint (see its own Code Index entry).
data CatOp a b where  -- initial algebra; 20 constructors incl. CatLoop/CatReturn/CatTagged
  CatId, CatCompose, CatFork, CatExl, CatExr, CatConst, CatInl, CatInr, CatFanIn,
  CatAssign, CatAssignWithRhs, CatLookup, CatLoop, CatReturn, CatEval, CatCall,
  CatSuspend, CatSplitValue, CatTry, CatTagged :: ...
-- Manual Show/Eq (GADTs can't derive); Eq via feq, which unsafeCoerce's to
-- CatOp () () and structurally matches -Wno-inaccessible-code/-overlapping-patterns.
```

### `PB.Analysis.SSA`

```haskell
-- Pure. Converts a procedure's body ('[Located BodyStmt]') into a
-- block-structured 'SsaProc' ('PB.Analysis.CatLower' consumes it directly by
-- unversioned variable name). NOT dominance-based SSA despite the name —
-- Plan 155 F1 (2026-07-08) deleted the dominator-tree/dominance-frontier/
-- phi-placement/variable-renaming machinery this module used to have: it
-- was fully vestigial (every phi's source list was always [], and renaming
-- only ever touched a version field nothing downstream read — PB has no
-- block-scoped locals, so there was never a case needing per-version
-- disambiguation). See the module's own top-of-file history note for the
-- full argument. ~396 lines (was ~700).
newtype SsaVar = SsaVar { svName :: Text }   -- no version field
data SsaVal = SsaConst Expr | SsaVarRef SsaVar | SsaBinOp BinOp SsaVal SsaVal | SsaNot SsaVal | SsaNull
data SsaAssign = SsaAssign { saVar :: SsaVar, saRhs :: SsaVal }
data SsaBlock = SsaBlock { sbAssigns :: [SsaAssign], sbTerm :: SsaTerm }
data SsaTerm = SsaGoto Text | SsaBranch SsaVal Text Text
             | SsaSwitch SsaVal [(SsaVal, Text)] Text | SsaReturn (Maybe SsaVal)
             | SsaBreak | SsaContinue
data SsaProc = SsaProc { spName :: Text, spBlocks :: Map.Map Text SsaBlock
                        , spEntry :: Text, spVars :: [SsaVar] }
  -- spVars: every assigned var, one entry per assignment, block-declaration
  -- order. Not consumed by CatLower (which walks spBlocks directly) — kept
  -- for tests/debugging only.
buildSsa :: ScopedTypeEnv -> Text -> [Located BodyStmt] -> SsaProc
-- Internal (not exported): assignTarget, lhsToExpr, rawArgsToExpr, headDef,
-- buildEdgeMap, cfgBlockToSsa, findLoopBackEdgeStmts, findLoopHeaderStmts,
-- stmtToAssigns, exprToSsaVal, cfgTermToSsa, doCondExpr, findControlStmt,
-- findEdgeLabel.
```

### `PB.Analysis.CatLower`

```haskell
-- Pure. SSA -> CatOp lowering (the categorical pipeline's largest, most
-- intricate stage; all of Plan 144's loop-nesting machinery and most of
-- Plan 146's correctness fixes live here). Split from CatOp.hs Plan 151.
-- Plan 155 F1 (2026-07-08): compilePhiAssignments deleted — it composed
-- against PB.Analysis.SSA's phi machinery, which was always a no-op (see
-- that module's own history note). compileTerm/compileLoopTerm/
-- compileLoopBranchPath no longer take a "prevBlock"/"blockId" argument
-- (it existed only to feed that dead call).
data CompileCtx = CompileCtx { ccEnv :: ScopedTypeEnv, ccUserFns :: Set Text, ccMergePoints :: Set Text }
compileSsa :: ScopedTypeEnv -> Set.Set Text -> SsaProc -> CatOp () ()
-- Internal (not exported): computeMergePoints, termSuccessors, computeLoopHeaders,
-- computeLoopNestParents, computeAllLoopExits, computeLoopBodyBlocks,
-- discoverReachable, canReach, determineLoopExitTarget, compileBlock,
-- compileLoopBody, ssaValToExpr, compileTerm,
-- compileLoopTerm, compileLoopBranchPath, isLoopExit, compileAssigns,
-- compileAssign, compileCallExpr.
```

### `PB.Analysis.GraphBuilder`

```haskell
-- Pure (GraphBuilder monad is a bare State, never IO). CatOp -> flat InstrGraph
-- flattening (the "GraphBuilder" target from Plan 144 Phase 4), plus LowCat
-- (the monomorphic CatOp bridge -- no unsafeCoerce, deterministic pattern
-- matching) and the public one-call pipeline entry point. Split from
-- CatOp.hs Plan 151. CpsNode/CpsGraph/buildCpsGraph/compileCatToCps renamed
-- to InstrNode/InstrGraph/buildInstrGraph/compileCatToInstr in Plan 152
-- (the "CPS" name was inaccurate -- this is a flat, PC-indexed instruction
-- array, not continuation-passing style).
data LowCat = LId | LCompose .. | LAssignWithRhs .. | LFanIn .. | LLoop ..
            | LInl | LInr | LSplitValue | LEval .. | LFork .. | LCall ..
            | LSuspend .. | LReturn | LTagged .. | LErasable
toLowCat :: CatOp a b -> LowCat
extractCondLowCat :: LowCat -> Expr
-- Plan 149 Phase 1 (wiring diagrams): WiringPayload/collectWiring/
-- compileProcedureToLowCat. LErasable/CatTry are empirically dead for real
-- procedures (0/7667 across both corpora, Plan 149 Phase 0) -- LowCat is
-- reused as-is for the wire term, no new type. collectWiring extracts every
-- distinct LTagged blockId's content exactly once into a side map; the
-- ToJSON LowCat instance (PB.Pipeline.Serialise) serialises LTagged as a
-- bare {tag,blockId} reference with NO inlined payload -- a naive fold that
-- walks LTagged's inner content directly reproduces Plan 150's exact
-- multiplicative node-blowup one layer up (found empirically: the Phase 0
-- survey script hung for 15+ minutes until this dedup was added).
data WiringPayload = WiringPayload { wpTerm :: LowCat, wpShared :: Map.Map Text LowCat }
collectWiring :: LowCat -> (LowCat, Map.Map Text LowCat)
compileProcedureToLowCat :: ScopedTypeEnv -> Set.Set Text -> [Located BodyStmt] -> LowCat
newtype GraphBuilder a = GraphBuilder { runBuilder :: State BuilderState a }
data BuilderState = BuilderState { bsNodes, bsNextPc, bsSourceLines, bsExitPc, bsBlockPcMemo }
initState :: BuilderState
allocateNode :: InstrNode -> GraphBuilder Int
registerNodeAt :: Int -> InstrNode -> GraphBuilder ()
finalizeGraph :: Int -> BuilderState -> InstrGraph
compileCatToInstr :: CatOp a b -> Int -> GraphBuilder Int
buildInstrGraph :: CatOp () () -> InstrGraph
-- Unified entry point: the sole compiler. Seeds steLocal from body's own
-- BsLocalVar decls (collectBodyLocals) before compiling, so classifyExpr can
-- resolve locally-declared datastore/datawindow/transaction variable types.
compileProcedureViaCatOp :: ScopedTypeEnv -> Set.Set Text -> [Located BodyStmt] -> InstrGraph
-- Plan 163 Phase 3 (2026-07-10): PB.Analysis.SchFootprint.foldSchFootprint
-- needs the raw compiled CatOp term (via foldCat), which neither sibling
-- above exposes (one flattens to InstrGraph, the other to LowCat). Same
-- buildSsa/compileSsa pipeline, one step shallower; deliberately not
-- factored to share code with the other two (same rationale as
-- compileProcedureToLowCat's own doc comment -- SSA is now compiled a
-- third time per procedure, pre-existing duplication pattern, not new).
compileProcedureToCatOp :: ScopedTypeEnv -> Set.Set Text -> [Located BodyStmt] -> CatOp () ()
```

### `PB.Analysis.CatInterp`

```haskell
-- Direct Haskell execution of a compiled CatOp term (the "Interp" target) --
-- used for testing, without going through GraphBuilder/InstrGraph or the TS
-- runtime. Parallels PB.Analysis.InstrInterp (interprets the flat InstrGraph
-- GraphBuilder produces instead) -- Plan 146's semantic-equivalence oracle
-- cross-checks the two. Split from CatOp.hs Plan 151.
data InterpState = InterpState { isEnv :: Map.Map Text Value, isTrace :: [TraceEvent], isMocks :: MockResponses }
newtype ReturnUnwind = ReturnUnwind InterpState  -- thrown by CatReturn to unwind past all enclosing loops
newtype Interp a b = Interp { runInterp :: a -> StateT InterpState IO b }
interpretLoop :: Interp a (Either a b) -> Interp a b
runInterpIO :: Interp a b -> a -> IO b  -- fresh empty env/trace/mocks, discards final InterpState
runCat :: CatOp a b -> Interp a b       -- Plan 148 Phase 3: now `runCat = foldCat` (Interp specialization)
```

### `PB.Analysis.InstrGraph`

```haskell
-- Pure. Shared InstrNode/InstrGraph types + canonical-shape helpers for
-- hand-trace/golden-fixture tests. Renamed from PB.Analysis.CpsCompile in
-- Plan 151 Phase 2b (2026-07-06) — the monadic compileProcedure compiler
-- this module used to house was deleted in Plan 144 Phase 5 Step 7; the
-- sole compiler is now PB.Analysis.GraphBuilder.compileProcedureViaCatOp.
-- parseArgList/collectBodyLocals moved out to PB.Analysis.CallClassify in
-- the same Phase 2b — they're generic AST/type helpers with nothing to do
-- with this module's own InstrNode/InstrGraph types.
--
-- Renamed again from PB.Analysis.CpsGraph in Plan 152 (2026-07-06), along
-- with every CpsNode constructor and the JSON wire tags, the DuckDB
-- procedures.cps_graph_json column (-> instr_graph_json), the Python
-- "cpsGraph" dict key (-> "instrGraph"), and the TS
-- ui/packages/interpreter/src/cps/ directory (-> src/instr/). "CPS" was an
-- inaccurate name for this flat, PC-indexed instruction array (it has no
-- nested closures, so it isn't continuation-passing style) — see Plan 151's
-- "Explicitly NOT part of this plan" section for the Stage 0 rationale and
-- Plan 152 for the full cross-language rename record.
data InstrNode = InstrAssign {..} | InstrBranch {..} | InstrGoto {..} | InstrCall {..}
               | InstrSuspend {..} | InstrReturn {..} | InstrNop {..} | InstrCallProc {..}
data InstrGraph = InstrGraph { igNodes, igEntry, igSuspensionPoints, igSourceMap }
-- ShapeNode/canonicalize/normalizeCallTag: canonical BFS-numbered shape of an
-- InstrGraph with names/values erased, for hand-trace/golden-fixture tests.
data ShapeNode = SAsgn Int | SBrnch Int Int | SGoto Int | SCall Int
               | SSusp Text Int | SRet | SNop Int | SCProc Int
canonicalize     :: InstrGraph -> [ShapeNode]
normalizeCallTag :: ShapeNode -> ShapeNode  -- SCProc n -> SCall n (cosmetic tag-only divergence)
```

### `PB.Analysis.Dataflow` (Plan 111a)

```haskell
-- Pure intra-procedural dataflow: def-use + reaching definitions.
extractDefsUses      :: CfgBlock -> BlockFlow
reachingDefinitions  :: Cfg -> Map Text BlockFlow -> (Map Text (Set Text), Map Text (Set Text))
analyzeProcedure     :: Text -> Text -> Cfg -> ProcFlow   -- obj, proc, cfg
-- analyzeWorkspace (Pass 6, writes proc_defs.json/proc_uses.json) is deferred to 111d-1.
data DefSite = DefSite { dsVar :: Text, dsBlock :: Text, dsStmtIdx :: Int, dsLine :: Maybe Int, dsKind :: Text }
data UseSite = UseSite { usVar :: Text, usBlock :: Text, usStmtIdx :: Int, usLine :: Maybe Int, usKind :: Text }
data BlockFlow = BlockFlow { bfBlockId :: Text, bfGen :: Set Text, bfKill :: Set Text, bfDefs :: [DefSite], bfUses :: [UseSite] }
data ProcFlow  = ProcFlow  { pfObject :: Text, pfProc :: Text, pfBlocks :: Map Text BlockFlow
                           , pfReachingIn :: Map Text (Set Text), pfReachingOut :: Map Text (Set Text)
                           , pfAllDefs :: Map Text [DefSite], pfAllUses :: Map Text [UseSite] }
-- walkExprIdents counts the ExCall callee root as a use (matches Python core/dataflow.py).
```

### `PB.Analysis.Taint` (Plan 111 — 111b/c/d-2)

```haskell
-- Taint analysis: source/sink classification, BFS propagation, path tracing.
-- JSON path: reads proc_defs/uses, resolved_calls, global_vars from JSON files.
-- DuckDB path: reads from DB via PB.Pipeline.DuckDb query helpers.
-- Classifies sources (SELECT INTO, event params) and sinks (INSERT/UPDATE/DELETE/EXECUTE)
-- from AST. extractSqlStmts recurses into BsIf/BsFor/BsDo/BsChoose, not just top-level BsRaw.
-- Propagates through intra-proc def-use chains and inter-proc
-- arg/return/global edges (computed internally from resolved_calls).
data TaintSource = TaintSource { tsFile, tsObject, tsProcName, tsVarName, tsSourceType :: Text, tsLine :: Maybe Int }
data TaintSink   = TaintSink   { tskFile, tskObject, tskProcName, tskVarName, tskSinkType, tskSeverity :: Text, tskLine :: Maybe Int }
data TaintPath   = TaintPath   { tpSource :: TaintSource, tpSink :: TaintSink, tpSteps :: [TaintStep], tpSeverity, tpCategory :: Text }
data TaintStep   = TaintStep   { tstObject, tstProcName, tstVarName :: Text, tstLine :: Maybe Int, tstStepKind, tstDescription :: Text }
data TaintAnnotation = TaintAnnotation { taFile, taObject, taProcName, taBlockId :: Text, taIsTaintEntry, taIsTaintSink :: Bool, taTaintedVars :: [Text }
data InterprocEdge = InterprocEdge { ieCallerObject, ieCallerProc :: Text, ieCallerLine :: Maybe Int, ieCalleeObject, ieCalleeProc, ieEdgeKind, ieVarName, ieCallerContext, ieCalleeContext :: Text }
data ProcSummaryReturnFlow = ProcSummaryReturnFlow { psrfObject, psrfProc, psrfLhsVar :: Text }
data ProcedureSummary = ProcedureSummary { psFile, psObject, psProcName :: Text, psParamsIn, psGlobalsRead, psGlobalsWritten :: [Text], psReturnFlowsTo :: [ProcSummaryReturnFlow] }
data TaintResult = TaintResult { trSources :: [TaintSource], trSinks :: [TaintSink], trPaths :: [TaintPath], trAnnotations :: [TaintAnnotation], trEdges :: [InterprocEdge], trProcedureSummaries :: [ProcedureSummary] }
data DefRow  -- FromJSON for proc_defs.json (file, object, proc_name, var_name, block_id, stmt_index, line, kind)
data UseRow  -- FromJSON for proc_uses.json
data ResolvedCallRow  -- FromJSON for resolved_calls.json
data GlobalVarRow     -- FromJSON for global_vars.json; field key is "name" (NOT "var_name" — bug fixed 2026-06-24)
classifySources    :: [SqlStmt] -> [ProcMeta] -> [TaintSource]
classifySinks      :: [SqlStmt] -> [TaintSink]
buildInterprocEdges :: [ResolvedCallRow] -> [DefRow] -> [UseRow] -> Set Text -> [ProcMeta] -> [InterprocEdge]
buildProcedureSummaries :: [InterprocEdge] -> [DefRow] -> [UseRow] -> Set Text -> [ProcMeta] -> [ProcedureSummary]
propagateTaint     :: [TaintSource] -> [DefRow] -> [UseRow] -> [InterprocEdge] -> (Set (Text,Text,Text), Provenance)
traceTaintPath     :: TaintSource -> TaintSink -> Provenance -> [TaintStep]
buildTaintAnnotations :: Set (Text,Text,Text) -> [TaintSource] -> [TaintSink] -> [DefRow] -> [UseRow] -> [TaintAnnotation]
taintAnalysis      :: [ResolvedCallRow] -> [DefRow] -> [UseRow] -> Set Text -> Text -> SrFile -> TaintResult
```

### `PB.Analysis.TypeEnv`

```haskell
-- Cross-file type environment. Used by InstrGraph consumers + Runner (Plan 114 unified them).
data TypeEnv = TypeEnv { teVars :: Map Text PbType, teUserTypes :: Map Text Text }
buildWorkspaceTypeEnv :: [SrFile] -> TypeEnv
lookupVarType    :: Text -> TypeEnv -> Maybe PbType      -- case-insensitive
lookupUserType   :: Text -> TypeEnv -> Maybe Text        -- case-insensitive
lookupBaseType   :: Text -> TypeEnv -> Maybe Text        -- resolves var → base type, walks inheritance chain with cycle guard
withProcScope    :: [(Text, PbType)] -> TypeEnv -> TypeEnv  -- overlay params (shadow globals of same name)
-- extractTypeDecls (internal, feeds teUserTypes/weHierarchy) now applies
-- PB.AST.SourceFile.splitAncestorRef to tdAncestor before use (Plan 164
-- Phase A, 2026-07-10) -- a backtick-declared ancestor resolves to just the
-- class part, so lookupBaseType/isDescendantOf's chain walk doesn't
-- silently stop at a backtick-compound node.

-- Workspace-wide + per-procedure scoped env (built once per compile run /
-- once per procedure respectively); consumed by CallClassify/CatLower/
-- GraphBuilder's whole SSA->CatOp pipeline.
data WorkspaceEnv = WorkspaceEnv
  { weGlobals      :: Map.Map Text PbType
  , weInstanceVars :: Map.Map Text (Map.Map Text PbType)  -- object name -> instance vars
  , weHierarchy    :: Map.Map Text Text                   -- full inheritance map
  }
buildWorkspaceEnv :: [SrFile] -> WorkspaceEnv

-- steObject/steControlIndex (Plan 164 D4, 2026-07-10): the enclosing
-- object name and workspace-wide ControlIndex, added so
-- CallClassify.resolveLvalueType can resolve a multi-segment dotted chain
-- (e.g. tab1.page1.uo_epidom) via PB.Analysis.ControlHierarchy
-- .resolveMemberChainType instead of only ever inspecting the first
-- segment. Piggybacks on ScopedTypeEnv the same way steHierarchy already
-- does -- one opaque value threaded through the whole compile pipeline,
-- no signature changes needed in CatLower/GraphBuilder/CompileCtx.
data ScopedTypeEnv = ScopedTypeEnv
  { steGlobal       :: Map.Map Text PbType
  , steInstance     :: Map.Map Text PbType
  , steLocal        :: Map.Map Text PbType   -- params only in P2a; body locals added in P2b
  , steHierarchy    :: Map.Map Text Text
  , steObject       :: Text          -- enclosing object; root for multi-hop chain resolution
  , steControlIndex :: ControlIndex  -- from PB.Analysis.ControlHierarchy
  }
procEnv :: WorkspaceEnv -> ControlIndex -> Text -> [(Text, PbType)] -> ScopedTypeEnv
-- Gained the ControlIndex param in Plan 164 D4 (was: WorkspaceEnv -> Text ->
-- params -> ScopedTypeEnv). Callers: Runner.hs passes its workspace-wide
-- controlIdx (already built for SchFootprint's SetItem resolution, Plan 164
-- Phase C); Emit.hs's single-file wrapSrFile builds `buildControlIndex [sf]`
-- locally (same single-file scope buildWorkspaceEnv [srFile] already has).
lookupScopedVar :: Text -> ScopedTypeEnv -> Maybe PbType  -- case-insensitive; steLocal > steInstance > steGlobal
```

### `PB.Analysis.TypeResolve` (Plan 109 — Pass 5)

```haskell
-- Pure. Produces resolved_types.json / resolved_calls.json / global_vars.json.
extractLocalVars  :: Text -> Text -> SrFile -> [LocalVar]   -- file, object, sf
extractCallSites  :: Text -> Text -> SrFile -> [CallSite]
extractGlobalVars :: Text -> Text -> SrFile -> [GlobalVar]
resolveTypes :: [LocalVar] -> Set Text -> Set Text -> [ResolvedType]   -- objs, userTypes; falls back to control-name inference
resolveCalls :: [CallSite] -> Map Text (Set Text) -> Map Text Text -> Set Text -> Set Text -> [ResolvedCall]
buildInheritsMap :: [SrFile] -> Map Text Text
-- buildInheritsMap now applies PB.AST.SourceFile.splitAncestorRef to
-- tdAncestor before storing the parent value (Plan 164 Phase A,
-- 2026-07-10) -- same fix/reasoning as TypeEnv.extractTypeDecls above;
-- fixes a latent gap where a backtick-declared ancestor (e.g. PowerBuilder's
-- "w_form_tab2`page1" extend-ancestor's-own-control syntax) made
-- ancestorChain/resolveVirtual silently stop, since no object is ever
-- literally named the raw compound string.
buildProcMap     :: [SrFile] -> Map Text (Set Text)
buildObjectSet, buildUserTypeSet :: [SrFile] -> Set Text
parseParams :: Text -> [(Text, PbType)]          -- "ref long al_row" → ("al_row", PtPrimitive "long")
classifyPbType :: PbType -> Set Text -> Set Text -> (Text, Maybe Text)  -- (kind, target)
classifyControlType :: Text -> Maybe Text  -- dw_main → datawindow (naming convention)
-- extractDwControlBindings (Plan 148 Phase 3, 2026-07-07): the DW-control ->
-- DW-object binding extraction the Phase 3 infra-slice session found
-- missing. Walks srTypeBlocks; a block's tbBody containing a "dataobject"-
-- named (case-insensitive) BsLocalVar with an ExStr literal init binds
-- (owner, control) -> dwName, where (owner, control) = (tdWithin, tdName)
-- when tdWithin is Just, else (tdName, "this") for the object's own outer
-- TypeBlock. Static-only by design: does not follow runtime aliasing
-- (ctrl = other.uo.dw, real corpus pattern in w_misth_fylo_form.srw) — no
-- binding produced rather than guessing.
extractDwControlBindings :: Text -> SrFile -> [DwControlBinding]
-- findLiteralDataObject (Plan 164 Phase B, 2026-07-10): the "dataobject"-
-- literal-BsLocalVar scan extractDwControlBindings always did, promoted
-- from a local `where`-bound helper to a top-level export so
-- PB.Analysis.ControlHierarchy.buildControlIndex can reuse it verbatim
-- instead of reimplementing the same scan a third time (already duplicated
-- once, separately, in Emit.extractWindowLayout).
findLiteralDataObject :: [Located BodyStmt] -> Maybe Text
-- Record types: LocalVar{lvFile,lvObject,lvProcName,lvVarName,lvRawType,lvIsParam,lvScopeLine}
--   CallSite{csFile,csObject,csFromProc,csToName,csCallType,csLine}
--   GlobalVar{gvFile,gvObject,gvName,gvType,gvMods}
--   ResolvedType{rtFile,rtObject,rtProcName,rtVarName,rtRawType,rtKind,rtTarget,rtIsParam,rtScopeLine}
--   ResolvedCall{rcFile,rcObject,rcFromProc,rcToName,rcCallType,rcLine,rcTargetObject,rcTargetProc,rcKind,rcConfidence}
--   DwControlBinding{dcbFile,dcbObject,dcbControlName,dcbDwName}
--   (lvPbType exists but is excluded from JSON.)
```

### `PB.Analysis.ControlHierarchy` (Plan 164 Phase B, done 2026-07-10; key qualification Phase E, done 2026-07-10)

```haskell
-- Pure. Workspace-wide control/object hierarchy index + multi-hop
-- member-chain resolver -- generalizes TypeResolve.extractDwControlBindings
-- (per-file) to walk a dotted chain (e.g. tab1.page1.uo_epidom.dw) across
-- file boundaries. All ControlDecl Text fields except cdDwBinding are
-- lowercased at construction time (case-insensitive lookup).
data ControlDecl = ControlDecl
  { cdOwner :: Text, cdName :: Text, cdAncestorType :: Text
  , cdOverridesName :: Maybe Text, cdDwBinding :: Maybe Text }
type ControlIndex = Map.Map (Text, Text, Text) ControlDecl   -- (root, owner, name), all lowercased
buildControlIndex :: [SrFile] -> ControlIndex
-- Uses TypeResolve.findLiteralDataObject for cdDwBinding. root = fst
-- (srPrimaryObject sf) for whichever file declared the TypeBlock -- the
-- Phase E fix. A flat (owner, name) key (Phase B's original design)
-- collided across unrelated windows redeclaring a common generic
-- child-control name -- CONFIRMED IN PRODUCTION (Plan 164 Phase C,
-- 2026-07-10): 11 windows in the openpay corpus alone redeclare "page1"
-- within "tab1", so last-file-wins Map.fromList bias picked an arbitrary
-- one, defeating Phase C's real-corpus SetItem-resolution gate even though
-- the resolver was correct on an isolated fixture. Qualifying by root (each
-- window's own redeclaration gets its own entry) fixed it: openpay's
-- cat_footprint_columns reached the targeted 2 rows for w_misth_fylo_form.

resolveMemberChainType      :: ControlIndex -> Map.Map Text Text -> Text -> [Text] -> Maybe Text
resolveMemberChainDwBinding :: ControlIndex -> Map.Map Text Text -> Text -> [Text] -> Maybe Text
-- Both take a starting object and chain segments (e.g. "w_misth_fylo_form",
-- ["tab1","page1","uo_epidom","dw"]); the Map.Map Text Text is an inherits
-- map (TypeResolve.buildInheritsMap's raw, case-sensitive output is fine --
-- normalized internally once per call). Public signatures are unchanged
-- since Phase B -- obj already serves as root==owner for the first hop, so
-- Phase E's key-shape change needed zero caller changes (Runner.hs,
-- SchFootprint.hs).
--
-- Each hop resolves via lookupScoped (Phase E; replaces the old
-- lookupWithAncestry): direct (root,owner,name) lookup, else walk root's
-- own class-ancestor chain via the inherits map (cycle-safe on root), then
-- unwinds any D1 cdOverridesName chain (cycle-safe on (root,owner,name))
-- to a fully-resolved terminal ControlDecl. lookupScoped distinguishes two
-- modes by whether root == owner at the call's start: "coupled" (true at
-- the very first hop, and again right after a has-a jump -- "does this
-- class directly declare a control called name") walks owner in lock-step
-- with root on ancestor-chain fallback; "decoupled" (owner is a literal
-- parent-control name distinct from root, e.g. continuing into page1
-- within tab1) holds owner fixed and only root climbs. The same
-- distinction governs D1 override-unwinding, derived for free from
-- foundRoot == cdOwner decl (no separate flag threaded) -- naively always
-- switching both root and owner to cdAncestorType decl on every override
-- (matching Phase B's original 2-tuple-owner-only formula) would mis-scope
-- a *nested* override's target (page1's own override must stay scoped to
-- the literal tab1 in the ancestor's own file, not jump to the ancestor
-- class's top-level scope).
--
-- Continuing to the NEXT segment tries two (root, owner) pairs in order,
-- since a single strategy can't distinguish them from a per-file view: (1)
-- the resolved control's own literal name with root held fixed (the
-- "visual tree" convention -- every file in one window's own ancestor
-- chain redeclares a nested control `within <literal-name>`, so the same
-- literal name is the right scope at every level, still within the SAME
-- window's own declaration space); (2) only if that fails, switching BOTH
-- root and owner to the fully-resolved ancestor type (the "has-a"
-- convention -- an embedded instance of a *different* class has its own
-- children declared `within <ClassName>` in that class's own file, never
-- under the instance name its container gave it -- e.g. uo_epidom's `.dw`
-- control is declared `within uo_misth_fylo_epidom_grid`, not `within
-- uo_epidom`, in uo_misth_fylo_epidom_grid's OWN separate file).
-- resolveMemberChainType returns the fully-unwound terminal's cdAncestorType
-- (the true base type). resolveMemberChainDwBinding does NOT use the same
-- full-unwind value for the binding -- it returns the CLOSEST override's
-- cdDwBinding found while unwinding (first Just wins, closest to furthest),
-- since a more-derived override's own literal dataobject must win over
-- whatever a generic ancestor declares (or, commonly, doesn't declare)
-- further up -- confirmed against real data: uo_misth_fylo_epidom_grid's own
-- `dw` control sets dataobject="dw_misth_fylo_epidom_list", but its D1
-- override target (u_grid's own `dw`, `from datawindow`) sets none at all;
-- a naive full-unwind-for-everything design would have returned Nothing for
-- exactly the case this module exists to resolve (Plan 163 Phase 3's
-- "openpay 0/6" SetItem gap). Both Nothing when any hop is unresolvable --
-- no guessing past what the workspace actually declares.
-- Verified end-to-end against the real fylo.pbl/w_misth_fylo_form.srw +
-- afxlib.pbl/w_form_tab2.srw + fylo.pbl/uo_misth_fylo_epidom_grid.sru +
-- afxlib.pbl/u_grid.sru fixture (openpay corpus): tab1.page1.uo_epidom.dw
-- from w_misth_fylo_form resolves to type "datawindow" / binding
-- "dw_misth_fylo_epidom_list". Wired into production since Phase C; full
-- workspace-scale correctness confirmed by Phase E (real --db ingestion:
-- openpay cat_footprint_columns 0->2 for w_misth_fylo_form, PowerBuilder-
-- Example stayed at 5, no regression).
```

### `PB.Analysis.Builtins`

```haskell
-- PB built-in function/method name sets for call classification (Plan 109b).
builtinFnNames     :: Set Text     -- free functions (used by resolveCalls)
builtinMethodNames :: Set Text     -- class methods
```

### `PB.Analysis.SchemaCategory` (Plan 148 Phase 1b/2, 2026-07-07)

```haskell
-- Pure. The DB schema as a free category (Sch). Objects are (table,column)
-- pairs and SQL-statement/DW-retrieve instances; morphisms are the "legs" a
-- statement has into columns it reads/writes, plus FK morphisms from DW
-- JOIN blocks and DDL foreign keys. Span encoding of a hyperedge -- see
-- doc/plan/148-db-schema-category.md "Design" section for the rationale.
-- Reuses TableRef from PB.Pipeline.SqlParse (does not redefine it).
data StmtId = SqlStmtId { siFile, siObject, siProc :: Text, siLine :: Int }
            | DwRetrieveId { siFile, siDwName :: Text }
data SchObject = ColumnObj TableRef Text | StmtObj StmtId
data LegKind   = LegReads | LegWrites | LegRetrieve | LegFk
-- LegSource (Plan 163 Phase 4, D3, 2026-07-10): supersedes the old FkSource
-- type (FkDdl | FkDwJoin, a second field meaningful only on LegFk rows) --
-- every SchMorphism now carries provenance, tagging which analysis
-- technique found it. Orthogonal to StmtId's front-end tag (DW/PS/future
-- PL/SQL) and to LegKind (the leg's direction/role).
data LegSource = SrcSqlText | SrcCatFootprint | SrcDwRetrieve
               | SrcDwJoin | SrcDwWhere | SrcDdlFk
renderLegSource :: LegSource -> Text
-- SrcSqlText->"sql_text", SrcCatFootprint->"cat_footprint",
-- SrcDwRetrieve->"dw_retrieve", SrcDwJoin->"dw_join",
-- SrcDwWhere->"dw_where", SrcDdlFk->"ddl_fk"
data SchMorphism = SchMorphism { legFrom, legTo :: SchObject, legKind :: LegKind, legSource :: LegSource }
data SchGraph  = SchGraph { sgObjects :: Set.Set SchObject, sgLegs :: [SchMorphism]
                          , sgOut, sgIn :: Map.Map SchObject [SchMorphism] }
schObjectKey :: SchObject -> Text   -- canonical DB key (object_key/from_key/to_key)

-- Free-category path structure (composable leg chains; Phase 2 traversal target).
data SchPath = SchPath { spFrom, spTo :: SchObject, spLegs :: [SchMorphism] }
idPath      :: SchObject -> SchPath
composePath :: SchPath -> SchPath -> Maybe SchPath   -- Nothing iff spTo p /= spFrom q

splitColumnRef :: Text -> Maybe (TableRef, Text)
-- Last-dot split (namespace.table.column), lowercased. Nothing for
-- unqualified text or a malformed ref (trailing dot etc).

-- SchemaInputs' first five fields are Analysis-owned "read-shape" row types
-- -- distinct from (but same-shaped as) PB.Pipeline.DuckDb's write-side row
-- types (DwJoinRow/SqlStmtColumnRow/CatalogColumnRow/CatalogFkRow), same
-- split as TypeResolve.ResolvedCall (write) vs. Taint.ResolvedCallRow
-- (read) for resolved_calls. Keeps PB.Analysis.* free of any
-- PB.Pipeline.DuckDb/duckdb-ffi dependency. DuckDb.hs's
-- queryDwRetrieveColumns/queryDwJoinLegs/querySqlCols/queryCatColumns/
-- queryCatFks return these types directly (new FromRow orphan instances).
data DwRetrieveColRow = DwRetrieveColRow { drcFile, drcDwName :: Text, drcNamespace :: Maybe Text, drcTable, drcColumn :: Text }
data DwJoinLegRow     = DwJoinLegRow { djlFile, djlDwName, djlLeftRef, djlRightRef :: Text }
data SqlColRow        = SqlColRow { scStmt :: StmtId, scNamespace :: Maybe Text, scTable :: Maybe Text, scColumn :: Text, scIsWrite :: Bool }
-- scTable = Nothing for an ambiguous unqualified column (old-style implicit
-- join, no catalog to resolve against) -- buildSchema skips these rows
-- rather than guessing; they produce no ColumnObj/leg.
data CatColumnRow = CatColumnRow { cclNamespace :: Maybe Text, cclTable, cclColumn :: Text }
data CatFkRow     = CatFkRow { cfrFromNamespace :: Maybe Text, cfrFromTable, cfrFromColumn :: Text
                              , cfrToNamespace :: Maybe Text, cfrToTable, cfrToColumn :: Text }
data SchemaInputs = SchemaInputs { inDwRetrieveColumns :: [DwRetrieveColRow], inDwJoins :: [DwJoinLegRow]
                                  , inDwWriteColumns :: [DwRetrieveColRow], inDwWhereColumns :: [DwRetrieveColRow]
                                  , inSqlColumns :: [SqlColRow], inCatFootprintColumns :: [SqlColRow]
                                  , inCatalogColumns :: [CatColumnRow]
                                  , inCatalogFks :: [CatFkRow], inDefaultNamespace :: Maybe Text }
-- inCatFootprintColumns (Plan 163 Phase 3, 2026-07-10): same SqlColRow shape
-- and resolve treatment as inSqlColumns, sourced from
-- PB.Analysis.SchFootprint.foldSchFootprint (dynamic-dispatch writes, e.g. a
-- DataWindow SetItem call) instead of sqlglot text extraction. Kept as its
-- own field (not merged into inSqlColumns) so each row's producing
-- technique stays distinguishable for a future leg_source column (Phase 4).
-- buildSchema folds it through the same mkSqlLegs helper inSqlColumns uses.
--
-- inDwWriteColumns/inDwWhereColumns (Plan 163 Phase 6, 2026-07-10): wires
-- PB.Analysis.DwFootprint.dwRetrieveFootprint's LegWrites/LegReads legs
-- (DW update-table columns / catalog-gated WHERE-operand columns) into
-- production -- same DwRetrieveColRow shape as inDwRetrieveColumns, reusing
-- its existing FromRow instance (dw_write_columns/dw_where_columns are new
-- DuckDb tables, same 5-column shape as dw_retrieve_columns). buildSchema's
-- dwWriteLegs/dwWhereLegs comprehensions mirror dwRetrieveLegs exactly
-- (StmtObj (DwRetrieveId ..) <-> ColumnObj), just LegWrites/SrcDwRetrieve
-- and LegReads/SrcDwWhere respectively instead of LegRetrieve/SrcDwRetrieve.
-- Real-corpus-verified: 559 write legs, 175 WHERE-read legs (openpay),
-- exact match to Phase 2's own predicted counts. dwRetrieveFootprint's
-- LegRetrieve/LegFk legs are NOT also fed through these fields -- Runner.hs's
-- compileOne keeps only LegWrites/LegReads from its dwRetrieveFootprint
-- call, since inDwRetrieveColumns/inDwJoins already cover retrieve/FK.
--
-- IMPORTANT (found wiring this in, not anticipated by the plan): DW-sourced
-- writes are deliberately EXCLUDED from cli's get_co_update_rituals/
-- get_decomposition_candidates ritual-evidence query (`_CO_WRITE_SQL` filters
-- `leg_source != 'dw_retrieve'`) even though they're fully present in
-- schema_morphisms/get_footprint/get_column_usage. A DW's update=yes column
-- set is a *design-time* "this form treats these columns as one editable
-- unit" fact -- PowerBuilder's generated Update() rewrites the whole SET
-- clause from the buffer every save, regardless of which field the user
-- touched, so it can't attest "these changed together in this save" the way
-- a PS write does. Blending the two into one co_write_support number
-- inflated this corpus's ritual count 45->1685 and its (previously zero,
-- genuinely verified) violation count 0->1092 -- see doc/plan/163-unified-
-- statement-footprint.md's Open Question #5 for the full rationale, and
-- its still-open follow-on: report DW-column-grouping as its own,
-- lower-confidence evidence type rather than only omitting it.
buildSchema :: SchemaInputs -> SchGraph   -- total, pure
-- Catalog-only columns (no statement/JOIN touches them) still become
-- objects with no legs -- a free normalization signal (dead-column
-- candidates); see done-condition verification below for real counts.
-- inDefaultNamespace (Plan 157 Phase 1, 2026-07-09): a local unexported
-- resolveTableRef helper resolves a Nothing-namespace TableRef (built at
-- the sqlLegs/dwRetrieveLegs/dwJoinLegs construction sites) to
-- TableRef (Just ns) tbl iff inCatalogColumns actually defines (ns, tbl)
-- -- never guessed; already-qualified refs and DDL-sourced legs
-- (ddlFkLegs, catalogOnlyObjects) are untouched. This is what unifies an
-- unqualified SQL/DW-retrieve column with the catalog's schema-qualified
-- ColumnObj for the same physical table (the root cause behind an
-- empty-looking column-affinity/decomposition/FK-graph query for any
-- table whose real touches are all unqualified -- see BACKLOG/doc/plan/
-- 157-default-namespace.md).

-- Traversal (Phase 2, 2026-07-07). Shared cycle-safe walker: a path-local
-- visited set means an object already on the current path is never
-- revisited, so recursion terminates even on a real cyclic FK graph
-- (corpus-confirmed: misth_final_ypal.kodfinal <-> misth_final.kodfinal).
-- Each returns one SchPath entry per distinct reachable object, not a
-- bare reachability boolean.
blastRadius        :: SchGraph -> SchObject -> [SchPath]   -- forward via sgOut; every result's spFrom == seed
validationWalkBack :: SchGraph -> SchObject -> [SchPath]   -- backward via sgIn; every result's spTo == seed
data ValidationConstraint = ValidationConstraint { vcColumn :: SchObject, vcDescription :: Text }
-- vcColumn expected to be a ColumnObj. Hand-seeded fixture, not inferred.
constraintWriters :: SchGraph -> ValidationConstraint -> [StmtId]
-- Dedup'd StmtIds reachable backward from vcColumn (SqlStmtId writers +
-- DwRetrieveId retrieves), direct or via an FK chain.

-- Plan 153 D5 (2026-07-07): the "rewrite cost" of moving a column --
-- union of blastRadius + validationWalkBack, collapsed to the shortest
-- path per distinct reachable StmtObj (ColumnObj-only endpoints, e.g. an
-- FK hop with no statement at the far end, are dropped). Consumed by
-- PB.Pipeline.Passes.runPass10, which materializes one row per (seed
-- column, target statement, leg) to decomposition_coslice for every
-- ColumnObj in the corpus -- Python's get_decomposition_candidates never
-- recomputes reachability, only reads this table.
columnCoslice :: SchGraph -> SchObject -> [SchPath]
```

### `PB.Analysis.SchFootprint` (Plan 148 Phase 3, done 2026-07-07)

```haskell
-- Pure. The functor F : CatOp -> Sch_|_ (design doc's "(a) Categorical
-- structure" amendment), implemented as a second instance of CatOp.hs's
-- Category/Cartesian/Cocartesian/Effectful classes rather than a
-- hand-written match -- foldCat folds any compiled CatOp term into it.
data FunctorCtx = FunctorCtx
  { fcStmtObj         :: StmtId                              -- CatOp carries no line info; any edge is procedure-granularity
  , fcTypeEnv         :: ScopedTypeEnv
  , fcDwColumns       :: Map.Map Text [(TableRef, Text)]      -- DW object name -> (table,col) targets, lowercased key
  , fcControlBindings :: Map.Map (Text, Text) Text            -- (object, control) -> dw name, all lowercased
  }
controlBindingsMap :: [DwControlBinding] -> Map.Map (Text, Text) Text  -- from TypeResolve.extractDwControlBindings
dwColumnsFromRows  :: [DwRetrieveColRow] -> Map.Map Text [(TableRef, Text)]  -- from dw_retrieve_columns rows
newtype SchFootprint a b = SchFootprint { runSchFootprint :: FunctorCtx -> Set.Set SchMorphism }
-- Elliott's "compiling to categories" constant-annotation category: erases
-- a/b entirely. id/exl/exr/inl/inr = const Set.empty; (.)/(&&&)/(|||) = 
-- pointwise union. loopK propagates the loop body's own footprint (not a
-- constant empty one) -- a static, iteration-count-oblivious analysis must
-- still count whatever the body touches.
--
-- callProc recognizes a "<ctrl>.SetItem(row, <literal col>, value)" call
-- (name ending ".setitem", case-insensitive) and resolves it via
-- fcControlBindings then fcDwColumns to a real LegWrites SchMorphism; any
-- lookup miss (unbound control, dynamic column arg, unknown column) is
-- Set.empty, no guessing. Deliberately hooks callProc, not suspend:
-- SetItem is not (and should not become) a suspending call -- unlike
-- Retrieve/Open/Close it's a synchronous in-process buffer write, and
-- 'suspend'/CatSuspend is the mechanism the interpreter/UI runtime use to
-- mean "must await an external response". SetItem already compiles to
-- CatCall (PB.Analysis.CallClassify.dwMethods omits "setitem"), so this
-- needed zero changes to CallClassify. suspend and the ExHostVar case
-- remain unimplemented -- not needed; callProc alone reaches Phase 3's
-- done-condition against a real corpus example (verified: w_dw_copy.srw's
-- `dw_dest.SetItem(ll_Cnt, "id", li_Data)`, value flowing through
-- li_Data <- dw_source.GetItemNumber(...), resolves to a LegWrites edge on
-- sales_order_items.id via dw_dest's static `DataObject="d_items"` binding
-- and d_items.srd's real retrieve columns -- an edge Phase 1's BsRaw/SQL-
-- text extraction cannot see since there is no SQL statement in this
-- procedure at all).
foldSchFootprint :: FunctorCtx -> CatOp a b -> Set.Set SchMorphism

-- runtimeDwAliasBindings (Plan 164 Phase C / D3, done 2026-07-10): the
-- second, dynamic source Runner.hs's compileOne merges into
-- fcControlBindings alongside controlBindingsMap's static one. Scans a
-- procedure body for BsAssign lhs rhs where lhs is a bare
-- datawindow/datastore-typed instance-or-local var (checked via
-- lookupScopedVar) and rhs is a multi-segment member-chain lvalue (e.g.
-- idw_epidom = tab1.page1.uo_epidom.dw); resolves rhs via
-- PB.Analysis.ControlHierarchy.resolveMemberChainDwBinding. BsAssignExpr is
-- not scanned -- classifyBodyStmt only emits it when the LHS does NOT parse
-- as a plain Lvalue, which a bare instance var always does. Recurses into
-- if/for/do/choose (mirrors Taint.extractSqlStmts); any lookup miss
-- contributes nothing, no guessing. Real-corpus-verified (unit test, not
-- just synthetic): w_misth_fylo_form.srw's of_open assigns the alias,
-- if_kodfylo_changed calls SetItem on it -- two DIFFERENT procedures, which
-- is why compileOne aggregates this file-wide (Map.unions over every
-- procedure's own runtimeDwAliasBindings call, each with steLocal seeded
-- via CallClassify.collectBodyLocals), not per-procedure.
--
-- FIXED (Plan 164 Phase E, done 2026-07-10 -- was a KNOWN LIMITATION found
-- via this same real-corpus verification): ControlHierarchy's ControlIndex
-- used to key on (owner, name) using only the immediate tdWithin name,
-- which collided across unrelated windows reusing a common generic
-- child-control name (e.g. "page1" within "tab1", declared by 11 different
-- windows in the openpay corpus) -- confirmed via cabal repl over the full
-- 422-file corpus to make the workspace-wide resolveMemberChainDwBinding
-- call above land on a real-but-wrong DW name for w_misth_fylo_form's own
-- chain in production (the isolated 4-file fixture this module's own test
-- uses resolved correctly even before the fix -- the collision only
-- manifested at full-corpus scale). Phase E qualified ControlIndex's key
-- to (root, owner, name), root = the declaring file's own top-level object
-- -- see PB.Analysis.ControlHierarchy's own entry above for the full
-- design. Confirmed via real --db ingestion: openpay's
-- cat_footprint_columns now reaches 2/2 rows for w_misth_fylo_form.
runtimeDwAliasBindings
  :: ControlIndex -> Map.Map Text Text -> Text -> ScopedTypeEnv
  -> [Located BodyStmt] -> Map.Map (Text, Text) Text
```

### `PB.Analysis.DwFootprint` (Plan 163 Phase 2, done 2026-07-10; wired into production Phase 6, 2026-07-10)

```haskell
-- Pure. The "Fdw" half of Plan 163's cospan (schema <- statement, tagged by
-- front-end), sibling to PB.Analysis.SchFootprint's "Fps" functor. Unlike
-- SchFootprint (folds a compiled CatOp term), a DW retrieve has no control
-- flow -- this is a total walk over the already-parsed DwTable/DwRetrieve
-- record straight into the same Set SchMorphism codomain. Deliberately
-- reproduces all four leg categories (column list, update-table, WHERE,
-- joins) directly from the AST -- overlaps with PB.Analysis.SchemaCategory
-- .buildSchema's existing row-based dwRetrieveLegs/dwJoinLegs producers on
-- purpose. Real openpay-corpus row-count diff (134 real .srd files, real
-- catalog_columns): LegRetrieve 863 -> 863 (exact match, corroborates the
-- row-based producer), LegFk FkDwJoin 52 distinct edges both ways (192 raw
-- rows in schema_morphisms is the same 52 edges un-deduped -- sgLegs is a
-- list, not a Set), LegWrites 0 -> 559 (new), LegReads/WHERE 0 -> 175 (new,
-- DDL-catalog-gated). See doc/plan/163-unified-statement-footprint.md
-- Phase 2 for the full diff table.
--
-- Phase 6 wiring (2026-07-10): PB.Pipeline.Runner's compileOne PsDw branch
-- now calls dwRetrieveFootprint for real and keeps only its LegWrites/
-- LegReads legs (LegRetrieve/LegFk are dropped at that call site --
-- inDwRetrieveColumns/inDwJoins already persist those, via the pre-existing
-- row-based producers this module's own LegRetrieve/LegFk output is
-- reconciled against above -- keeping both would double-count in
-- schema_morphisms). See PB.Analysis.SchemaCategory's SchemaInputs entry
-- for the inDwWriteColumns/inDwWhereColumns fields this feeds, and its own
-- note on why cli's get_co_update_rituals deliberately excludes these
-- writes from ritual/violation detection.
data DwFootprintCtx = DwFootprintCtx
  { dfcCatalogTables    :: Set.Set (Text, Text)             -- (namespace, table) DDL defines -- feeds resolveTableRef
  , dfcCatalogColumns   :: Set.Set (Maybe Text, Text, Text)  -- (namespace, table, column) DDL defines -- WHERE-leg gate only
  , dfcDefaultNamespace :: Maybe Text
  }
mkDwFootprintCtx :: [CatColumnRow] -> Maybe Text -> DwFootprintCtx  -- from the same catalog_columns rows buildSchema consumes
-- Recognizes a plain, unsubscripted 2- or 3-segment dotted ExLvalue
-- (table.column / namespace.table.column) as a column ref; any other shape
-- (subscript, 1 or 4+ segments, ExHostVar, literals, calls) -> Nothing.
-- Segment names lowercased, mirrors SchemaCategory.splitColumnRef.
lvalueColumnRef :: Expr -> Maybe (TableRef, Text)
-- file, dwName, the DwTable (not just DwRetrieve -- dtColumns/dtUpdate live
-- there, sibling to dtRetrieve). WHERE-derived LegReads legs are the only
-- catalog-gated category (via dfcCatalogColumns) -- LegRetrieve/LegWrites/
-- LegFk are never catalog-checked, matching buildSchema's existing column/
-- join producers, which don't check catalog membership either.
dwRetrieveFootprint :: DwFootprintCtx -> Text -> Text -> DwTable -> Set.Set SchMorphism
```

### `PB.Pipeline.FileWalk`

```haskell
walkFiles      :: (FilePath -> Bool) -> FilePath -> IO [FilePath]   -- [] if root missing
walkPsFiles    :: FilePath -> IO [FilePath]   -- .srf .srw .sru .srm .sra .srx
walkDwFiles    :: FilePath -> IO [FilePath]   -- .srd
walkAllSrFiles :: FilePath -> IO [FilePath]   -- any .sr<single-char>
```

### `PB.Pipeline.DuckDb`

```haskell
-- DuckDB-direct I/O for pbc --db mode. C FFI to libduckdb.dylib via duckdb-ffi.
-- Single-writer constraint: DuckConn is NOT thread-safe for concurrent appenders;
-- runModeDb uses MVar mutex (bridge path) or sequential mapM_ (no-bridge path).
-- Phase A appenders (one per table, create + destroy per run):
-- procedures.wiring_json (Plan 149 Phase 1): ProcRow gained prWiringJson,
-- positioned right after prInstrJson/instr_graph_json in both the DDL and
-- appendProcedures' column order (raw positional Appender -- order must
-- match). Populated from PB.Analysis.GraphBuilder's WiringPayload
-- (compileProcedureToLowCat + collectWiring), by both Runner.hs (--db mode)
-- and Emit.hs's injectCompiled ("wiring" key, JSON -o mode, withInstr only).
appendObjects, appendProcedures, appendDwObjects, appendDwControls :: DuckConn -> [row] -> IO ()
appendLocalVars, appendCallSites, appendGlobalVars :: DuckConn -> [row] -> IO ()
appendProcDefs, appendProcUses, appendSqlStmts :: DuckConn -> [row] -> IO ()
appendSqlStmtColumns, appendSqlStmtFilters :: DuckConn -> [row] -> IO ()
-- cat_footprint_columns (Plan 163 Phase 3, 2026-07-10): identical shape to
-- sql_statement_columns, populated by PB.Analysis.SchFootprint.foldSchFootprint
-- (currently: DataWindow SetItem calls with a literal column + a statically-
-- resolvable control binding) instead of sqlglot text extraction. Kept as
-- its own table (not merged into sql_statement_columns) for future
-- leg_source provenance tagging. Reuses SqlStmtColumnRow on the append side.
appendCatFootprintColumns :: DuckConn -> [SqlStmtColumnRow] -> IO ()
-- catalog_columns/catalog_pks/catalog_fks (Plan 148 Phase 1a-3, 2026-07-07):
-- static DDL catalog, row-oriented (namespace/table_name/column_name/ordinal
-- for columns+pks; +constraint_name/from_*/to_* for fks, one row per
-- from/to column pair for composite FKs). Populated once per DDL file (Oracle
-- hardening 2026-07-08: now once per --ddl arg, not once per run -- multiple
-- schema-tagged dumps each get their own parseDdl call) from
-- PB.Pipeline.Runner.catalogToRows, itself fed by PB.Pipeline.SqlParse.parseDdl.
appendCatalogColumns, appendCatalogPks, appendCatalogFks :: DuckConn -> [row] -> IO ()
-- catalog_checks (2026-07-08): (constraint_name, namespace, table_name,
-- predicate) -- named CHECK constraints, sqlglot's normalized-SQL predicate
-- text (not a re-parsed expression AST; see SqlParse's CatalogCheckConstraint
-- doc comment for why). Fed by the same per-DDL-file catalogToRows call.
appendCatalogChecks :: DuckConn -> [CatalogCheckRow] -> IO ()
appendParseErrors :: DuckConn -> [row] -> IO ()
-- dw_retrieve_columns (Plan 148 Phase 1b, 2026-07-07): (file, dw_name,
-- namespace, table_name, column_name), one row per qualified DwRetrieve
-- column ref (splitColumnRef'd from drColumns in Runner.hs's PsDw branch --
-- fills the "drColumns never reaches DuckDB" survey gap).
appendDwRetrieveColumns :: DuckConn -> [DwRetrieveColumnRow] -> IO ()
-- dw_write_columns/dw_where_columns (Plan 163 Phase 6, 2026-07-10): same
-- 5-column shape as dw_retrieve_columns, populated from Runner.hs's
-- compileOne PsDw branch (dwRetrieveFootprint's LegWrites/LegReads legs).
appendDwWriteColumns, appendDwWhereColumns :: DuckConn -> [DwRetrieveColumnRow] -> IO ()
-- dw_retrieve_where (Track SCHEMA-BUGS, 2026-07-09): (file, dw_name, idx,
-- exp1, op, exp2, logic) -- one row per DwWhereClause in a DwRetrieve's
-- drWhere, idx preserves clause order (zip [0..] at the Runner.hs
-- construction site). Mirrors dw_joins's shape exactly. Restores a feature
-- that datawindows.py/tables.py already queried (exception-guarded, so it
-- silently returned [] rather than erroring) but the table never existed in
-- initSchema -- found incidentally during Plan 157 Phase 4.5.
appendDwRetrieveWhere :: DuckConn -> [DwRetrieveWhereRow] -> IO ()
-- Phase B read helpers (SELECT → typed rows):
queryLocalVars, queryCallSites, queryGlobalVars :: DuckConn -> IO [row]
queryObjInfo     :: DuckConn -> IO [(Text, Text)]       -- (file, object) pairs per PS file
queryProcDefs    :: DuckConn -> IO [Taint.DefRow]
queryProcUses    :: DuckConn -> IO [Taint.UseRow]
queryResolvedCalls :: DuckConn -> IO [Taint.ResolvedCallRow]
queryTaintInputs :: DuckConn -> IO [Taint.TaintFileInputs]  -- includes procedure-less PS objects via objects table
queryProcInfos   :: DuckConn -> IO [TypeResolve.LocalVar]   -- for Pass 5 resolveTypes
queryDwObjectSet :: DuckConn -> IO (Set Text)
-- SchemaCategory read-side queries (Plan 148 Phase 1b, 2026-07-07): return
-- PB.Analysis.SchemaCategory's own read-shape types directly (new FromRow
-- orphan instances here), consumed by Passes.hs's runPass9.
queryDwRetrieveColumns :: DuckConn -> IO [SchemaCategory.DwRetrieveColRow]
-- queryDwWriteColumns/queryDwWhereColumns (Plan 163 Phase 6): same query
-- shape as queryDwRetrieveColumns, reading dw_write_columns/dw_where_columns.
queryDwWriteColumns, queryDwWhereColumns :: DuckConn -> IO [SchemaCategory.DwRetrieveColRow]
queryDwJoinLegs        :: DuckConn -> IO [SchemaCategory.DwJoinLegRow]
querySqlCols           :: DuckConn -> IO [SchemaCategory.SqlColRow]
-- queryCatFootprintColumns (Plan 163 Phase 3): same shape/query as
-- querySqlCols, reading cat_footprint_columns instead -- the existing
-- FromRow SqlColRow instance is reused verbatim, no new instance needed.
queryCatFootprintColumns :: DuckConn -> IO [SchemaCategory.SqlColRow]
queryCatColumns        :: DuckConn -> IO [SchemaCategory.CatColumnRow]
queryCatFks            :: DuckConn -> IO [SchemaCategory.CatFkRow]
-- Phase B write appenders:
appendResolvedTypes, appendResolvedCalls :: DuckConn -> [row] -> IO ()
appendInterprocEdges, appendProcSummaries :: DuckConn -> [row] -> IO ()
appendTaintSources, appendTaintSinks, appendTaintPaths, appendTaintAnnotations :: DuckConn -> [row] -> IO ()
appendDeadCode   :: DuckConn -> [DeadCode.DeadProcedure] -> IO ()
-- schema_objects/schema_morphisms (Plan 148 Phase 1b, 2026-07-07): written
-- by runPass9 from SchemaCategory.buildSchema's SchGraph. object_key/
-- from_key/to_key columns hold SchemaCategory.schObjectKey's canonical
-- string form. schema_morphisms' leg_source column (Plan 163 Phase 4,
-- 2026-07-10; was fk_source, FK-only) holds renderLegSource (legSource m)
-- for every row -- see SchemaCategory's LegSource entry above.
appendSchemaObjects   :: DuckConn -> [SchemaCategory.SchObject]   -> IO ()
appendSchemaMorphisms :: DuckConn -> [SchemaCategory.SchMorphism] -> IO ()
-- decomposition_coslice (Plan 153 D5, 2026-07-07): written by runPass10,
-- one row per leg of each column's columnCoslice path. seed_key/target_key
-- are schObjectKey strings; direction is "forward" (blastRadius) or
-- "backward" (validationWalkBack), derived by comparing the path's spFrom
-- to the seed at flatten time (SchPath itself carries no direction tag).
-- leg_ordinal orders a target's legs within its (seed_key, target_key)
-- path. Python's get_decomposition_candidates (cli/api) is the sole reader.
appendDecompositionCoslice :: DuckConn -> [(SchemaCategory.SchObject, [SchemaCategory.SchPath])] -> IO ()
-- Generic EDB/IDB bridge (Plan 161, Souffle migration, 2026-07-11):
-- PB.Pipeline.Souffle needs to read/write relations whose column count is a
-- runtime value (Relation's relCols), not fixed by a Haskell type -- no
-- per-relation FromRow/appender pair is possible, so these three are the
-- dynamic-arity counterparts of the typed query/appender pairs above.
-- Every value round-trips as TEXT (every EDB relation currently fed through
-- -- keys, kinds, names -- is already string-shaped; a numeric column like
-- stmt's line is CAST to VARCHAR at read time since no rule inspects it
-- other than by equality/wildcard).
queryTextRows     :: DuckConn -> Text -> [Text] -> IO [[Text]]
-- table/view name, column names -> rows, in that column order, each value
-- CAST(... AS VARCHAR) at the SQL level (works regardless of underlying
-- column type). Backed by an internal, unexported `newtype TextRow = TextRow
-- [Text]` FromRow instance built on numFieldsRemaining/field (loops until no
-- fields remain, rather than a fixed-arity tuple instance).
recreateTextTable :: DuckConn -> Text -> [Text] -> IO ()
-- DROP TABLE IF EXISTS + CREATE TABLE with the given column names, all TEXT
-- -- the write-side counterpart of queryTextRows.
appendTextRows    :: DuckConn -> Text -> [[Text]] -> IO ()
-- Generic-arity appender (reuses the existing withRaw/aText/endRow
-- machinery) -- no per-arity ToRow instance needed.
-- Schema init:
withWriteConn    :: FilePath -> (DuckConn -> IO a) -> IO a
initSchema       :: DuckConn -> IO ()
```

---

## Token Efficiency

**Prefer SEARCH/REPLACE over full rewrites.** Use the Edit tool rather than rewriting whole files. Only rewrite when the diff would be larger than the file.

**Use `rg` before reading.** Locate the relevant lines before opening a file. `rg -l` to find which file, `rg -n` to find the line. NOTE: ripgrep does _not_ have a `--include` option.

**Budget every tool call.** On GLM-5, each Read of a 300-line file costs as much as writing 50 lines of production code. Before any tool call, ask: "does this directly produce the deliverable?" If not, skip it.

**Explore agents: max 1 per session.** Prefer reading 2–3 key files directly with `offset`+`limit` over launching broad exploration sweeps. Explore agents return ~4000 words each — that's ~15% of the session budget for a single agent. Three parallel agents is a non-starter.

**Never re-read files agents have summarized.** Trust agent output for planning. Only read files directly when you need exact line numbers for edits, and even then use `offset`+`limit` to read only the relevant section.

**Use `offset`+`limit` on every Read.** Read only the lines you need — typically the first 50–100 lines for type declarations, or a specific line range from `rg -n` output. Never read a full 300+ line file when you need one function.

**When the user gives exact paths or instructions, execute immediately.** No verification, no Glob, no "let me check." Especially when the user explicitly says not to verify.

**Parallel edits: verify paths first.** A single bad path in a batch of parallel edits causes the entire batch to fail. Verify all paths exist before launching the batch.

**Stop condition for research:** If you've spent >10% of budget on research/exploration and haven't produced any deliverable output, STOP researching and start writing. You can always fill in gaps from the document itself.

---

## Commit Discipline

**Do not run `git add` or `git commit`.** At the end of a session, after post-task grooming is complete, output two code blocks:

1. **Recommended commit message** — follows conventional-commit style; one subject line (≤72 chars) describing what changed and why; an optional blank-line body for multi-file changes.

```
feat(dw): implement block scanner + AST skeleton (DW-A1)

Parse .srd files into DataWindowFile with typed band/control/table stubs.
Corpus gate: 262 DW files return non-stub JSON.
```

1. **Recommended next-session seed prompt** — a self-contained paragraph the user can paste to start the next session. Include: charter, which plan file to read, key counts/baselines, and any prerequisite check.

```
Charter: DW-A2 — implement typed `table(...)` parsing per doc/plan/21-dw-a2.md.
Prerequisite: DW-A1 complete and `cabal test` passing (619 tests).
Baseline: 262 DW files non-stub; ExRaw ≤ 1; BsRaw other ≤ 18.
Start at Stage 0: read doc/plan/21-dw-a2.md in full, then read
PB.AST.DataWindow and PB.Grammar.DataWindow to locate the stub functions
that need replacing.
```

These are proposals only — the user decides when and whether to commit.

**Other commit rules (when the user does commit):**

- One commit per stage (or per logical unit within a stage)
- Commit message: what changed and why, not how
- Do not commit with a warning-dirty `cabal build`
- Failing test stubs (Stage 2) may be committed; mark them clearly with `assertFailure "unimplemented: ..."`
- Before committing parser changes: `./pb check-corpus`
  The error count must not increase. Baseline: 0 errors / 1051 files.
- Any new failure categories found during a session must be recorded in `doc/plan/BACKLOG.md` before committing.
