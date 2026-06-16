# Navigation Philosophy

## 1. The Problem

In a pure reducer architecture, routing state is global — there is exactly one
place in `AppState` that says which view is active.  Features are local: an
`objectsReducer` knows about objects and procedures, not about the app's full
routing vocabulary.

The tension surfaces as soon as a feature needs to drive a view change.  When a
user clicks an object, the objects feature wants to say "switch to objectDetail
view and push `/objects/SomeObject` to the browser" — but it only sees its own
`ObjectsState`.  The routing type (`Route`, `NavigationAction`) lives at the
app boundary.  Threading it directly into `ObjectsEnv` or `ObjectsAction`
couples the feature to the app's full routing vocabulary.

This coupling takes three canonical forms:

- **Action coupling**: feature action types reference app-level navigation
  variants.
- **State coupling**: feature state carries the current view or navigation
  stack position.
- **Env coupling**: feature env carries a full dispatch channel back to the
  app.

All three break the feature boundary.  The feature that was once "knows about
objects" becomes "knows about the whole app."

## 2. TCA's Evolution

The Swift Composable Architecture (TCA) has worked through this problem publicly
across several major versions.

### Tree-based destinations (TCA ≤ 0.52)

Each parent feature defines a `Destination` enum with one case per navigable
child:

```swift
enum Destination {
  case detail(ItemDetailFeature.State)
  case add(AddItemFeature.State)
}
```

The parent reducer uses `ifLet` / `ifCaseLet` pullbacks to scope child actions
and state into the parent tree.  Navigation is implicit: presenting a child is
just setting `destination = .detail(state)`.

This works well for strictly hierarchical apps but becomes awkward when:

- A feature needs to reach a sibling rather than a direct child.
- The destination enum grows to include cases unrelated to the feature's core
  logic.
- Deep nesting requires many intermediate pullback hops.

### Stack-based navigation (TCA ≥ 0.54 / 1.x)

`NavigationStack` with `StackState<Destination>` replaced much of the tree
approach.  Features are scoped by position in the navigation stack rather than
by a fixed parent–child type relationship.  Push and pop are ordinary state
mutations; each element in the stack carries its own reducer.

The stack model naturally supports back-navigation and deep-link restoration,
but it imposes a path-based metaphor that does not map cleanly to tab- or
panel-based UIs where there is no meaningful "back."

### URL parser/printer binding

TCA 1.x introduced `navigationDestination` matching and route parsing via
parser-printer combinators.  A bidirectional codec maps `URL → StackElement`
and back, enabling type-safe deep-link restoration.  The cost: every
destination must appear in the route codec, and the codec must live at the app
boundary where both the URL vocabulary and the feature vocabulary are in scope.

The ergonomic tension persists: type-safe destinations require the parent to
enumerate all possible children; feature isolation requires each feature to be
unaware of the parent's destination type.

## 3. Elm / Redux Patterns

In the Elm architecture, the parent `update` function receives child messages
verbatim and can intercept them for routing:

```elm
update msg model =
  case msg of
    ItemMsg (Item.Selected id) ->
      -- parent sees the child action and decides to route
      ( { model | view = Detail id }, Cmd.none )
    ItemMsg subMsg ->
      let (items, cmd) = Item.update subMsg model.items
      in  ( { model | items = items }, Cmd.map ItemMsg cmd )
```

This is architecturally clean: only the parent makes routing decisions, and the
child carries no routing dependency.  The drawback is that the parent must know
the semantics of every child action that might imply navigation.  As features
grow, the parent accumulates a catalogue of "what does each child action mean
for routing?" — coupling that scales with every new feature action.

Redux addresses the same issue with middleware: a `react-router` integration
intercepts dispatched actions and imperatively navigates outside the reducer.
This avoids parent-knows-child coupling but introduces implicit side effects
invisible to tests.

## 4. `pullbackWithNav` HOF

The approach chosen here injects `env.navigate` at the pullback layer rather
than embedding routing in the feature action type or requiring parent-level
action interception.

### Mechanism

`pullbackWithNav` is a higher-order combinator that wraps `pullback` with
navigation interception:

```ts
export function pullbackWithNav<
  NavAction,
  S, A,
  E extends { navigate(a: NavAction): Effect<never> },
  PS, PA, PEnv
>(
  child: Reducer<S, A, E>,
  get: (parent: PS) => S,
  match: (action: PA) => A | null,
  widen: (a: A) => PA,
  getEnv: (env: PEnv) => Omit<E, "navigate">,
  widenNav: (nav: NavAction) => PA,
): Reducer<PS, PA, PEnv>
```

When dispatching to a child reducer, the combinator:

1. Constructs a synthetic `env.navigate` that captures each call synchronously
   into a `pending: PA[]` list, returning `Effect.none()` to the caller.
2. Runs the child reducer with that env.
3. After `reduce` returns, converts each captured nav call into an
   `Effect.send(widenNav(nav))`.
4. Merges those nav effects with any effects the child reducer returned.

```ts
const pending: PA[] = [];
const childEnv = {
  ...(getEnv(env) as E),
  navigate: (nav: NavAction): Effect<never> => {
    pending.push(widenNav(nav));
    return Effect.none();
  },
};
const eff = child(get(draft), local, childEnv);
const navEff = pending.length > 0
  ? Effect.merge(...pending.map(a => Effect.send<PA>(a)))
  : null;
return mergeNullable(eff?.map(widen), navEff);
```

The child reducer calls `env.navigate(...)` exactly as it calls any other env
function.  It neither knows nor cares that navigation is handled differently
from an API call.

### No action type pollution

The nav action is widened to `AppAction` by the combinator (`widenNav`), not by
the feature.  Feature action types remain domain-local:

```ts
// app/reducer.ts
const toNav = (nav: NavigationAction): AppAction => ({ tag: "nav", action: nav });

pullbackWithNav(objectsReducer, ..., toNav)
```

`ObjectsAction` never references `NavigationAction` directly.

### Composability with feature effects

Because nav calls are captured and emitted as `Effect.send`, they interleave
cleanly with feature effects via `Effect.merge`.  A single `select` action can
simultaneously:

- Update optimistic state (synchronous draft mutation).
- Emit a nav effect that switches the view and pushes the URL.
- Emit two parallel API fetch effects (object detail + source).

All four happen in one reduce call with no special ordering logic.

## 5. The `Route` Codec

Earlier iterations of this codebase used a stringly-typed route registry
(`pathToView`, `viewToPath`, `VIEW_PREFIX`) and required feature reducers to
make two separate calls on every navigation: one to `env.navigate` (to update
`NavState`) and a second to `env.pushUrl` (to push a URL string they
constructed manually).  The two calls could silently drift.

The current design replaces this with a typed discriminated union and an
exhaustive codec at `features/navigation/routes.ts`.

### `Route` — typed discriminated union

```ts
// features/navigation/types.ts

export type Route =
  | { view: "dashboard" }
  | { view: "objects" }
  | { view: "objectDetail";    name: string }
  | { view: "procedureDetail"; name: string; proc: string }
  | { view: "datawindows" }
  | { view: "dwDetail";        name: string }
  | { view: "diagrams" }
  | { view: "queries" }
  | { view: "search" }
  | { view: "explore" };

export type ViewName = Route["view"];   // derived — not an independent union
```

`NavState` holds a `Route` value, not a flat `ViewName`:

```ts
export interface NavState {
  route: Route;
}
```

### `print` and `parse`

```ts
// features/navigation/routes.ts

export function print(route: Route): string { /* exhaustive switch */ }
export function parse(path: string): Route  { /* split + switch, dashboard fallback */ }
```

`print` is an exhaustive `switch` — TypeScript errors if a new `Route` variant
is added without updating it.  `parse` splits the path on `/`, dispatches on
the first segment, and falls through to `{ view: "dashboard" }` for anything
unrecognised.

### Nav reducer owns URL state

The nav reducer is the single call-site for `env.pushUrl`:

```ts
// features/navigation/reducer.ts

case "navigate":
  draft.route = action.route;
  env.pushUrl(print(action.route));   // canonical URL derived from typed route
  return null;
```

Feature reducers call `env.navigate` with a fully-typed `Route` value.  They
never construct URL strings or call `pushUrl` directly.

```ts
// features/objects/reducer.ts — after the codec

case "select":
  env.navigate({ type: "navigate", route: { view: "objectDetail", name: action.name } });
  // no env.pushUrl — the nav reducer handles it
  return Effect.merge(env.getObject(...), env.getObjectSource(...));
```

### What the feature sees

```ts
export interface ObjectsEnv {
  getObjects(params: ...): Effect<ListObjectsResponse>;
  getObject(name: string): Effect<ObjectDetailResponse>;
  getObjectSource(name: string): Effect<ObjectSourceResponse>;
  getProcedure(obj: string, proc: string): Effect<ProcedureDetailResponse>;
  getAllObjects(): Effect<ListObjectsResponse>;
  navigate(action: NavigationAction): Effect<never>;
  // no pushUrl — that belongs to NavEnv only
}
```

### Deep-link restoration

`url-sync.ts` calls `parse(window.location.pathname)` on mount and dispatches
the resulting `Route` through a typed `switch`:

```ts
function dispatchFromRoute(dispatch: Dispatch<AppAction>, route: Route): void {
  switch (route.view) {
    case "objectDetail":
      dispatch({ tag: "objects", action: { type: "select", name: route.name } });
      break;
    case "procedureDetail":
      dispatch({ tag: "objects",
                 action: { type: "proc-select", objectName: route.name, procName: route.proc } });
      break;
    case "dwDetail":
      dispatch({ tag: "datawindows", action: { type: "select", name: route.name } });
      break;
    default:
      dispatch({ tag: "nav", action: { type: "navigate", route } });
  }
}
```

Parameterised routes dispatch into the relevant feature so the feature's normal
data-loading path fires — the same code path as a user click.  TypeScript
narrows `route.name` and `route.proc` only in the branches where they exist,
eliminating the previous magic-string param bag (`params.objectName`,
`params.dwName`, etc.).

## 6. Trade-offs and Limitations

**Feature knows `NavigationAction`.** `ObjectsEnv.navigate` accepts
`NavigationAction` explicitly.  The feature knows the routing *type*, just not
through its own action union.  This is weaker coupling than embedding routing
variants in `ObjectsAction`, but it is not zero coupling.  A fully decoupled
design would accept a generic `() => void` per destination slot, but that
sacrifices call-site clarity and makes destination-dependent parameters
impossible to express.

**Synchronous-only navigation.** `pullbackWithNav` only captures `env.navigate`
calls made during the synchronous body of the child reducer.  If a feature
needs to navigate conditionally on the result of an async API call, it must
dispatch a new feature action from the effect callback and navigate during
*that* action's synchronous reduce.  This is mildly awkward but keeps control
flow explicit and testable.

**`pushState` is always called on navigate.** The `createEnv` guard
(`if (path !== current) history.pushState(...)`) prevents duplicate history
entries, so deep-link restoration that triggers a feature `select` — which
calls `env.navigate`, which calls `print`, which calls `pushUrl` — is harmless:
the URL already matches and the guard skips the push.  But it means a redundant
`pushState` attempt is made on every deep-link boot.  A `replaceState` vs
`pushState` distinction could eliminate this if it ever becomes an observable
problem.

## 7. Future Directions

**`NavigationPath`-style stack.** For deep drill-down flows (object →
procedure → call-site → ...), a stack-based nav state would replace the flat
`Route` field.  Each push and pop would be a typed operation on a path stack.
`pullbackWithNav` would remain the injection mechanism; only `NavState` and
`NavigationAction` would change.  The `print`/`parse` codec would generalise to
encode a `Route[]` stack as a URL path.

**Typed `Destination` per feature.** Instead of a flat `Route` union at the
app boundary, each feature that owns a navigable destination could declare its
own destination type.  The nav reducer would fold these into the discriminated
union at the app level.  Impossible routing transitions would become
unrepresentable at the type level, and adding a new feature destination would
only require changing the feature module and the app-level combiner — not
scanning the codebase for magic strings.
