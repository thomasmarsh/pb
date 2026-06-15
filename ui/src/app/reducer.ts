// app/reducer.ts — App-level reducer: combines all feature reducers.
// Owns initialState() factory, the top-level reducer, and all app↔feature lenses.

import { pullback, combine } from "../core/reducer.js";
import { Effect } from "../core/effect.js";
import type { AppState } from "./state.js";
import type { AppAction } from "./actions.js";

import { navReducer, type NavEnv } from "../features/navigation/reducer.js";
import { exploreReducer, makeInitialExploreState, type ExploreEnv } from "../features/explore/reducer.js";
import { objectsReducer, type ObjectsEnv, initialObjectsState } from "../features/objects/reducer.js";
import { diagramsReducer, type DiagramsEnv, initialDiagramsState } from "../features/diagrams/reducer.js";
import { queriesReducer, type QueriesEnv, initialQueriesState } from "../features/queries/reducer.js";
import { searchReducer, type SearchEnv, initialSearchState } from "../features/search/reducer.js";

import type { NavigationAction, NavState } from "../features/navigation/types.js";
import type { ExploreAction } from "../features/explore/actions.js";
import type { ExploreState } from "../features/explore/types.js";
import type { ObjectsAction } from "../features/objects/actions.js";
import type { ObjectsState } from "../features/objects/types.js";
import type { DiagramsAction } from "../features/diagrams/actions.js";
import type { DiagramsState } from "../features/diagrams/types.js";
import type { QueriesAction } from "../features/queries/actions.js";
import type { QueriesState } from "../features/queries/types.js";
import type { SearchAction } from "../features/search/actions.js";
import type { SearchState } from "../features/search/types.js";

export type AppEnv = NavEnv & ExploreEnv & ObjectsEnv & DiagramsEnv & QueriesEnv & SearchEnv;

// ── Lenses (app-level: connect features to AppState) ─────────────────────────

const matchNav      = (a: AppAction): NavigationAction | null => a.tag === "nav"      ? a.action : null;
const matchExplore  = (a: AppAction): ExploreAction   | null => a.tag === "explore"   ? a.action : null;
const matchObjects  = (a: AppAction): ObjectsAction   | null => a.tag === "objects"   ? a.action : null;
const matchDiagrams = (a: AppAction): DiagramsAction  | null => a.tag === "diagrams"  ? a.action : null;
const matchQueries  = (a: AppAction): QueriesAction   | null => a.tag === "queries"   ? a.action : null;
const matchSearch   = (a: AppAction): SearchAction    | null => a.tag === "search"    ? a.action : null;

// ── Initial state ─────────────────────────────────────────────────────────────

export function initialState(): AppState {
  return {
    nav: {
      view: "dashboard",
      stats: null,
      objectDetail: null,
      sourceDetail: null,
      procedureDetail: null,
      allObjects: [],
      datawindows: { items: [], total: 0, q: "", loading: false },
      dwDetail: null,
    },
    objects: initialObjectsState,
    diagrams: initialDiagramsState,
    queries: initialQueriesState,
    search: initialSearchState,
    explore: makeInitialExploreState(),
  };
}

// ── Combined reducer ──────────────────────────────────────────────────────────

const _combined = combine<AppState, AppAction, AppEnv>(
  pullback<NavState, NavigationAction, AppState, AppAction, NavEnv, AppEnv>(
    navReducer,
    (s) => s.nav,
    matchNav,
    (a): AppAction => ({ tag: "nav", action: a }),
    (env) => env,
  ),
  pullback<ExploreState, ExploreAction, AppState, AppAction, ExploreEnv, AppEnv>(
    exploreReducer,
    (s) => s.explore,
    matchExplore,
    (a): AppAction => ({ tag: "explore", action: a }),
    (env) => env,
  ),
  pullback<ObjectsState, ObjectsAction, AppState, AppAction, ObjectsEnv, AppEnv>(
    objectsReducer,
    (s) => s.objects,
    matchObjects,
    (a): AppAction => ({ tag: "objects", action: a }),
    (env) => env,
  ),
  pullback<DiagramsState, DiagramsAction, AppState, AppAction, DiagramsEnv, AppEnv>(
    diagramsReducer,
    (s) => s.diagrams,
    matchDiagrams,
    (a): AppAction => ({ tag: "diagrams", action: a }),
    (env) => env,
  ),
  pullback<QueriesState, QueriesAction, AppState, AppAction, QueriesEnv, AppEnv>(
    queriesReducer,
    (s) => s.queries,
    matchQueries,
    (a): AppAction => ({ tag: "queries", action: a }),
    (env) => env,
  ),
  pullback<SearchState, SearchAction, AppState, AppAction, SearchEnv, AppEnv>(
    searchReducer,
    (s) => s.search,
    matchSearch,
    (a): AppAction => ({ tag: "search", action: a }),
    (env) => env,
  ),
);

export function reducer(draft: AppState, action: AppAction, env: AppEnv): Effect<AppAction> | null {
  return _combined(draft, action, env);
}
