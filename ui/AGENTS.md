# Explorer UI (TypeScript / SolidJS) — Subsystem Guide

Loaded automatically by Claude Code whenever a session reads or edits files
under `ui/`. This file covers frontend-specific rules only — session
protocol, the staged verification loop, commit discipline, documentation
style, and change-scope rules live in the root `AGENTS.md` and apply here too.

## UI Architecture Rules

These rules apply to all work under `ui/`. Violating them causes `ECONNREFUSED` noise in
tests, forces `vi.stubGlobal` hacks, and breaks the type-safety the architecture is built around.

### Rule 1 — No component calls `fetch`

**All HTTP calls flow exclusively through `AppEnv` methods.** Components never call `fetch`.
If a component needs server data, the sequence is always:

```
user action → store.dispatch(action) → reducer → env.method() → Effect → dispatch(result-action) → state update → component re-renders
```

Calling `fetch` inside a component (in `onMount`, `createResource`, a signal setter, etc.) bypasses
the env and fires a real HTTP request against a non-running server in tests. The reducer fetches
via `env`; the component only ever reads from the store snapshot.

If `pnpm test` shows `ECONNREFUSED` noise (not a test failure, just stderr), one of Rule 2's six
steps is missing an entry — never fix it with `vi.stubGlobal` (Rule 4).

### Rule 2 — Adding a new API call: the six-step checklist

Follow all six steps every time. Missing any one causes TypeScript errors or test noise.

1. **Feature `Env` interface** — add the typed method, e.g. in `features/datawindows/reducer.ts`:
   `getDwLayout(name: string): Effect<DataWindowFile>;`
2. **`ApiClient` interface + implementation** — in `ui/src/features/app/api-client.ts`, add the
   `Promise`-returning interface method and its `fetchJson(...)` implementation.
3. **`createEnv` wiring** — in the same file's `createEnv`:
   `getDwLayout: (n) => lift(() => api.getDwLayout(n)),`
4. **`mockEnv` in `ui/tests/helpers.tsx`** — add a no-op entry:
   `getDwLayout: () => Effect.none(),`
5. **Feature-local mock envs** — any test file with its own `const mockEnv: FeatureEnv` must also
   add the method. Find them with `rg -l "DatawindowsEnv\|ExploreEnv" ui/tests/`.
6. **Reducer usage** — return `Effect.merge(e1, e2)` when firing in parallel with another call
   (see Rule 5).

### Rule 3 — Navigation via `env.navigate()`, never dispatched directly

Feature reducers call `env.navigate(navAction)` to change the route — never return a nav action
as an `Effect` themselves (`Effect.send({ tag: "nav", ... })` is always wrong; it leaks the
app-level action shape into the feature).

`pullbackWithNav` (in `ui/src/core/reducer.ts`) intercepts `env.navigate` calls synchronously,
converts them to `Effect.send(widenNav(nav))`, and merges them with the feature's own effect in
the same dispatch cycle. See `doc/nav-philosophy.md` for full rationale.

```ts
case "select":
  draft.dwDetail = null;
  env.navigate({ tag: "navigate", route: { view: "dwDetail", name: action.name } });
  return env.getDW(action.name).map((data): MyAction => ({ tag: "detail-loaded", data }));
```

`navigate` must be declared in the feature's `Env` interface as
`navigate(action: NavigationAction): Effect<never>` — `pullbackWithNav` provides the
implementation at the app level; the feature never calls `history.pushState` or touches the nav
reducer directly.

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

---

## Testing

**Runtime test pattern.** When testing the PB interpreter / runtime reducer, use
`createMockRuntimeEnv` (controlled SQL responses) and `renderWindow()` (logical JSX output).
Never start the server or hit a real database in unit tests.

```ts
const mockEnv = createMockRuntimeEnv({
  misth_zpkrat: { rows: [{ kodkrat: "01" }], rowcount: 1, columns: ["kodkrat"] },
});
const ts = createTestStore(runtimeReducer, mockEnv, initialRuntimeState);
ts.send({ tag: "set-ast", ast });
ts.send({ tag: "run-event", owner: "w_test", event: "open" });
ts.receive({ tag: "sql-result", dwName: "dw", rows: MOCK_ROWS });
expect(ts.getState().controlValues["dw"]).toHaveLength(1);

const rendered = renderWindow(ast, ts.getState().controlValues, ts.getState().variables);
expect(rendered.dataWindows[0]!.rows).toHaveLength(1);
```

**TestStore assert pattern.** `ts.send`/`ts.receive` callbacks run on the PRE-action state —
describe mutations there (as shown above), not `expect()` assertions after the fact, and
describe ALL fields the action changes or the comparison fails.

---

## Renaming or adding a DuckDB column

`pb.duckdb`'s schema is owned by `compiler/src/PB/Pipeline/DuckDb.hs`, but a
rename reaches `ui/` whenever the column is part of the JSON wire format —
`ui/packages/platform/src/types/api.ts` and any component reading the field.
Before touching a column name a `ui/`-only session references, read
`compiler/AGENTS.md`'s "DuckDB Schema Standards" section first: it has the
naming conventions and the full five-layer consumer checklist.
