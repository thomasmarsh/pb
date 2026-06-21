# pb-ast — Working Protocol

## Quick Reference

```text
cd parser && cabal build                          # compile library + executables
cd parser && cabal build --enable-tests           # compile tests too
cd parser && cabal test                           # run test suite
cd parser && cabal test --test-show-details=direct # verbose output
./pb check-corpus                    # 0 errors / 1051 files = baseline
./pb debt                        # BsRaw + ExRaw debt + DW control coverage (both corpora)
./pb debt --no-build             # same, skip build step
cd cli && uv run pytest         # Python tool tests (cli/tests/ directory)
cd cli && uv run ruff check     # Python lint
cd cli && uv run pyright        # Python type check (0 errors baseline)
cd ui && pnpm typecheck         # TypeScript type check (explorer)
cd ui && pnpm lint              # ESLint (explorer)
cd ui && pnpm test              # Explorer reducer tests (64 tests)
cd ui && pnpm build             # Build explorer TS → static/dist/
PB_SQL_MOCK=1 uv run pb explore  # Run explorer with mock SQL (no MySQL needed)
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
rg -n "functionName" parser/src/
rg -l "LogicalLine" parser/src/
```

No change is proposed without a prior read of all relevant modules. Locate callers before modifying a function.

**Diagnosing corpus failures.** When the charter is to reduce corpus errors, sample raw error messages before touching code:

```bash
./pb check-corpus 2>&1 | grep "Files processed"   # get count

# sample 5 error messages from a temporary run:
OUT=$(mktemp -d)
cabal run --project-dir parser pb-runner -v0 -- -i example/openpay-0.1.1b-extract -o "$OUT" 2>/dev/null
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
entry). Use `pb_cli.core.ast_walker.walk_tagged`, which recurses into every dict value and list
item unconditionally and can't miss a tag regardless of which field a constructor nests its
children under. `walk_calls`/`count_branches`/`walk_bsraw`/`walk_exraw` are all built on it.

If you need ground truth on the wire format, don't trust committed example JSON (`output/` is
gitignored scratch and may be stale) — rebuild and run the binary directly:

```bash
cabal build --project-dir parser pb-runner
BIN=$(cabal list-bin --project-dir parser pb-runner)
$BIN -i <dir-with-one-srf> -o /tmp/pbout && python3 -m json.tool /tmp/pbout/*.json
```

**Diagnosing implementation debt.** When the charter targets BsRaw, ExRaw, or DW structural-field coverage, run the debt analyser first — do NOT re-derive the breakdown from scratch:

```bash
./pb debt --no-build
```

This prints:

- Per-corpus BsRaw category counts (`sql`, `decl`, `ctrl`, `handled`, `other`) — `other` is the actionable BsRaw target; the rest are correct or already handled.
- A ranked ExRaw breakdown by leading token with examples — these are expression-level `ExRaw` fallbacks still to be promoted to typed `Expr` constructors. Use this to pick the highest-value next ExRaw charter.
- **DW control coverage** — per-field percentage of `DwControl` structural fields (`name`, `band`, `id`, `x`, `y`, `width`, `height`, `visible`, `expression`, `tab_seq`) that are non-null across both corpora; top 15 control types by frequency. Use this to baseline before any DW-track session and confirm improvement after. Expected coverage for "real" display controls (text/column/compute/line/report/groupbox/rectangle/graph): ~78% on positional fields; `htmltable`/`htmlgen`/etc. export-generator controls will always be ~0% on these fields.

**Keep `cli/pb_cli/debt.py` in sync with any new `Expr` constructors.** When a new `ExXxx` constructor is added, confirm the ExRaw count drops correspondingly in the script output — it requires no code changes because it walks the live JSON, but the BACKLOG entry should quote the before/after counts.

**The DW coverage section is always-on** (not gated on a flag). Quote the before/after coverage percentages in BACKLOG entries for DW-track sessions.

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
cd cli && uv run ruff check && uv run pyright && uv run pytest
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

The custom Prelude is in `parser/src/PB/Prelude.hs`. These rules are non-negotiable.

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
- parser/app/Main.hs should have no functionality other than to call into parser/src/PB/Pipeline/Runner.hs with two arguments 1) input source dir path and 2) output JSON AST tree path
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
| Body: `try … catch … end try`           | all        | pending |
| Body: embedded SQL                      | .srw, .sru | pending |
| Body: assignment / call statements      | all        | done    |

---

## Module Placement

| Module          | Purpose                                                                                                                             |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `PB.AST.*`      | Data types only — no parsing logic (Located, Expr, BodyStmt, Type, SourceFile, DataWindow)                                          |
| `PB.Lexing.*`   | Tokenization, layout, string mode                                                                                                   |
| `PB.Grammar.*`  | megaparsec parsers (Body, File, Stream, DataWindow)                                                                                 |
| `PB.Pipeline.*` | Multi-step transformations: Preprocess, Walk, Runner, Serialise, CfgBuild, CpsCompile, Dataflow, Taint, TypeResolve, TypeEnv, PbApi |
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
  | BsRaw       Text                  -- SQL, event decls, unclassified (source text)
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

### `PB.Pipeline.Runner`

```haskell
runFile           :: FilePath -> Text -> Either Text Value   -- dispatches on extension via fileKind
collectStatements :: [LexLine] -> Either Text [Statement]
wrapSrFile        :: FilePath -> SrFile -> SrSpans -> TypeEnv -> Value
runModeFiles      :: FilePath -> FilePath -> IO ()   -- batch: 7 passes
runModeJsonl      :: FilePath -> IO ()               -- streaming, no cross-file inh
writeDataflowAnalysis :: FilePath -> [ParsedFile] -> IO ()  -- Pass 6 → proc_defs.json, proc_uses.json
writeTaintAnalysis    :: FilePath -> [ParsedFile] -> IO ()  -- Pass 7 → taint_*.json, interproc_edges.json, procedure_summaries.json
-- fileKind: .srd → DataWindow, .srp → Pipeline, .srj → Project, _ → PowerScript
-- runPowerScript: normalizeText → stripHeaders → tokenize → collectStatements
--                 → parseSrFileWithSpans → wrapSrFile; builds buildWorkspaceTypeEnv [srFile] per file
-- wrapSrFile injects per-procedure: meta (file/object/startLine), source_rendered,
--   cfg (buildCfg), cpsGraph (compileProcedure). Workspace TypeEnv built from all files in
--   runModeFiles; per-procedure overlay applied via withProcScope (parseParams paramsText) wsEnv.
-- collectStatements filters empty-token statements and surfaces the first LexError as Left Text
-- Note: leOffset in a LexError is always 0 (reports initial position state, not error position).
--       Only llStartLine (leSource e) is meaningful for diagnosis.
-- writeResolution writes resolved_types.json, resolved_calls.json, global_vars.json (Pass 5)
-- writeDataflowAnalysis reads resolved_types + CFG → proc_defs.json, proc_uses.json (Pass 6)
-- writeTaintAnalysis reads proc_defs/uses + resolved_calls + global_vars → taint_*.json, interproc_edges.json, procedure_summaries.json (Pass 7)
```

### `PB.Pipeline.Serialise`

```haskell
-- Orphan ToJSON instances for all PB.AST.* types and PB.Pipeline.Taint types.
-- Import as: import PB.Pipeline.Serialise ()
-- Brings ToJSON instances into scope; exports nothing explicitly.
-- Sum-type discriminator: "tag" key (string); single-field payload → "contents".
-- InterprocEdge, ProcedureSummary, ProcSummaryReturnFlow use manual instances
-- to match Python snake_case keys (caller_object, callee_proc, etc.).
```

### `PB.Pipeline.CfgBuild`

```haskell
-- Pure. buildCfg :: [Located BodyStmt] -> Cfg. Mirrors cfg_builder.py.
data CfgBlock = CfgBlock { cbId :: Text, cbStmts :: [Located BodyStmt], cbFirstLine :: Maybe Int, cbLastLine :: Maybe Int }
data CfgEdge  = CfgEdge  { ceSrc :: Text, ceDst :: Text, ceLabel :: Text }
data Cfg      = Cfg      { cfgEntry :: Text, cfgExits :: [Text], cfgBlocks :: [CfgBlock], cfgEdges :: [CfgEdge] }
-- Edge labels: "T"/"F" (branches), "" (fallthrough), "loop" (back-edge), "case:N".
```

### `PB.Pipeline.CpsCompile`

```haskell
-- Pure. Uses PB.Pipeline.TypeEnv.TypeEnv (the rich record, not a Map Text Text alias).
-- InheritGraph alias removed (Plan 114) — inheritance is in teUserTypes.
data CallKind = Pure | Suspend
classifyExpr :: TypeEnv -> Expr -> CallKind
compileProcedure :: TypeEnv -> [Located BodyStmt] -> CpsGraph
data CpsNode
  = CpsAssign  { anVar :: Text, anRhs :: Expr, anNext :: Int }
  | CpsBranch  { brCond :: Expr, brThenPc :: Int, brElsePc :: Int }
  | CpsGoto    { goTarget :: Int }
  | CpsCall    { clCallee :: Text, clArgs :: [Expr], clResult :: Maybe Text, clNext :: Int }
  | CpsSuspend { suEffect :: Text, suArgs :: [Expr], suVar :: Maybe Text, suContinuation :: Int }
  | CpsReturn  { reValue :: Maybe Expr }
  | CpsNop     { npNext :: Int }
data CpsGraph = CpsGraph { cgNodes :: [CpsNode], cgEntry :: Int, cgSuspensionPoints :: [Int], cgSourceMap :: [(Int, Int)] }
-- BsDestroy lv emits CpsAssign { anVar = lvHead lv, anRhs = ExNull } (Plan 115 item 1, done in Plan 114 session).
```

### `PB.Pipeline.Dataflow` (Plan 111a)

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

### `PB.Pipeline.Taint` (Plan 111 — 111b/c/d-2)

```haskell
-- Taint analysis: source/sink classification, BFS propagation, path tracing.
-- Reads proc_defs/uses, resolved_calls, global_vars from JSON. Classifies
-- sources (SELECT INTO, event params) and sinks (INSERT/UPDATE/DELETE/EXECUTE)
-- from AST. Propagates through intra-proc def-use chains and inter-proc
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
data GlobalVarRow     -- FromJSON for global_vars.json (just var_name)
classifySources    :: [SqlStmt] -> [ProcMeta] -> [TaintSource]
classifySinks      :: [SqlStmt] -> [TaintSink]
buildInterprocEdges :: [ResolvedCallRow] -> [DefRow] -> [UseRow] -> Set Text -> [ProcMeta] -> [InterprocEdge]
buildProcedureSummaries :: [InterprocEdge] -> [DefRow] -> [UseRow] -> Set Text -> [ProcMeta] -> [ProcedureSummary]
propagateTaint     :: [TaintSource] -> [DefRow] -> [UseRow] -> [InterprocEdge] -> (Set (Text,Text,Text), Provenance)
traceTaintPath     :: TaintSource -> TaintSink -> Provenance -> [TaintStep]
buildTaintAnnotations :: Set (Text,Text,Text) -> [TaintSource] -> [TaintSink] -> [DefRow] -> [UseRow] -> [TaintAnnotation]
taintAnalysis      :: [ResolvedCallRow] -> [DefRow] -> [UseRow] -> Set Text -> Text -> SrFile -> TaintResult
```

### `PB.Pipeline.TypeEnv`

```haskell
-- Cross-file type environment. Used by CpsCompile + Runner (Plan 114 unified them).
data TypeEnv = TypeEnv { teVars :: Map Text PbType, teUserTypes :: Map Text Text }
buildWorkspaceTypeEnv :: [SrFile] -> TypeEnv
lookupVarType    :: Text -> TypeEnv -> Maybe PbType      -- case-insensitive
lookupUserType   :: Text -> TypeEnv -> Maybe Text        -- case-insensitive
lookupBaseType   :: Text -> TypeEnv -> Maybe Text        -- resolves var → base type, walks inheritance chain with cycle guard
withProcScope    :: [(Text, PbType)] -> TypeEnv -> TypeEnv  -- overlay params (shadow globals of same name)
```

### `PB.Pipeline.TypeResolve` (Plan 109 — Pass 5)

```haskell
-- Pure. Produces resolved_types.json / resolved_calls.json / global_vars.json.
extractLocalVars  :: Text -> Text -> SrFile -> [LocalVar]   -- file, object, sf
extractCallSites  :: Text -> Text -> SrFile -> [CallSite]
extractGlobalVars :: Text -> Text -> SrFile -> [GlobalVar]
resolveTypes :: [LocalVar] -> Set Text -> Set Text -> [ResolvedType]   -- objs, userTypes
resolveCalls :: [CallSite] -> Map Text (Set Text) -> Map Text Text -> Set Text -> Set Text -> [ResolvedCall]
buildInheritsMap :: [SrFile] -> Map Text Text
buildProcMap     :: [SrFile] -> Map Text (Set Text)
buildObjectSet, buildUserTypeSet :: [SrFile] -> Set Text
parseParams :: Text -> [(Text, PbType)]          -- "ref long al_row" → ("al_row", PtPrimitive "long")
classifyPbType :: PbType -> Set Text -> Set Text -> (Text, Maybe Text)  -- (kind, target)
-- Record types: LocalVar{lvFile,lvObject,lvProcName,lvVarName,lvRawType,lvIsParam,lvScopeLine}
--   CallSite{csFile,csObject,csFromProc,csToName,csCallType,csLine}
--   GlobalVar{gvFile,gvObject,gvName,gvType,gvMods}
--   ResolvedType{rtFile,rtObject,rtProcName,rtVarName,rtRawType,rtKind,rtTarget,rtIsParam,rtScopeLine}
--   ResolvedCall{rcFile,rcObject,rcFromProc,rcToName,rcCallType,rcLine,rcTargetObject,rcTargetProc,rcKind,rcConfidence}
--   (lvPbType exists but is excluded from JSON.)
```

### `PB.Pipeline.PbApi`

```haskell
-- PB built-in function/method name sets for call classification (Plan 109b).
builtinFnNames     :: Set Text     -- free functions (used by resolveCalls)
builtinMethodNames :: Set Text     -- class methods
```

### `PB.Pipeline.Walk`

```haskell
walkFiles      :: (FilePath -> Bool) -> FilePath -> IO [FilePath]   -- [] if root missing
walkPsFiles    :: FilePath -> IO [FilePath]   -- .srf .srw .sru .srm .sra .srx
walkDwFiles    :: FilePath -> IO [FilePath]   -- .srd
walkAllSrFiles :: FilePath -> IO [FilePath]   -- any .sr<single-char>
```

---

## Token Efficiency

**Prefer SEARCH/REPLACE over full rewrites.** Use the Edit tool rather than rewriting whole files. Only rewrite when the diff would be larger than the file.

**Use `rg` before reading.** Locate the relevant lines before opening a file. `rg -l` to find which file, `rg -n` to find the line.

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
