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

## Testing

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
