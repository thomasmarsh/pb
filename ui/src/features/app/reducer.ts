// app/reducer.ts — App-level reducer: combines all feature reducers.
// Owns initialState() factory, the top-level reducer, and all app↔feature lenses.

import { pullback, pullbackWithNav, combine } from "../../core/reducer.js";
import { Effect } from "../../core/effect.js";
import type { AppState } from "./state.js";
import type { AppAction } from "./actions.js";

import { navReducer, type NavEnv } from "../navigation/reducer.js";
import { dashboardReducer, type DashboardEnv, initialDashboardState } from "../dashboard/reducer.js";
import { exploreReducer, makeInitialExploreState, type ExploreEnv } from "../explore/reducer.js";
import { objectsReducer, type ObjectsEnv, initialObjectsState } from "../objects/reducer.js";
import { datawindowsReducer, type DatawindowsEnv, initialDatawindowsState } from "../datawindows/reducer.js";
import { tablesReducer, type TablesEnv, initialTablesState } from "../tables/reducer.js";
import { diagramsReducer, type DiagramsEnv, initialDiagramsState } from "../diagrams/reducer.js";
import { queriesReducer, type QueriesEnv, initialQueriesState } from "../queries/reducer.js";
import { searchReducer, type SearchEnv, initialSearchState } from "../search/reducer.js";
import { errorsReducer, type ErrorsEnv, initialErrorsState } from "../errors/reducer.js";
import { runtimeReducer, type RuntimeEnv, initialRuntimeState, type RuntimeAction } from "../runtime/reducer.js";
import { windowManagerReducer } from "../window-manager/reducer.js";
import type { WindowManagerAction } from "../window-manager/types.js";
import { initialWindowManagerState } from "../window-manager/initial.js";

import type { NavigationAction } from "../navigation/types.js";
import { crumbsForRoute } from "../navigation/breadcrumb.js";
import type { DashboardAction } from "../dashboard/actions.js";
import type { ExploreAction } from "../explore/actions.js";
import type { ObjectsAction } from "../objects/actions.js";
import type { DatawindowsAction } from "../datawindows/actions.js";
import type { TablesAction } from "../tables/actions.js";
import type { DiagramsAction } from "../diagrams/actions.js";
import type { QueriesAction } from "../queries/actions.js";
import type { SearchAction } from "../search/actions.js";
import type { ErrorsAction } from "../errors/actions.js";
export type { RuntimeAction };

import type { Theme } from "./state.js";

export type AppEnv = NavEnv & DashboardEnv & ExploreEnv & ObjectsEnv & DatawindowsEnv & TablesEnv & DiagramsEnv & QueriesEnv & SearchEnv & ErrorsEnv & ThemeEnv & RuntimeEnv;

export interface ThemeEnv {
  loadTheme(): Effect<Theme>;
  applyTheme(theme: Theme): Effect<never>;
}

// ── Lenses (app-level: connect features to AppState) ─────────────────────────

const matchNav         = (a: AppAction): NavigationAction  | null => a.tag === "nav"         ? a.action : null;
const matchDashboard   = (a: AppAction): DashboardAction   | null => a.tag === "dashboard"    ? a.action : null;
const matchExplore     = (a: AppAction): ExploreAction     | null => a.tag === "explore"      ? a.action : null;
const matchObjects     = (a: AppAction): ObjectsAction     | null => a.tag === "objects"      ? a.action : null;
const matchDatawindows = (a: AppAction): DatawindowsAction | null => a.tag === "datawindows"  ? a.action : null;
const matchTables      = (a: AppAction): TablesAction      | null => a.tag === "tables"       ? a.action : null;
const matchDiagrams    = (a: AppAction): DiagramsAction    | null => a.tag === "diagrams"     ? a.action : null;
const matchQueries     = (a: AppAction): QueriesAction     | null => a.tag === "queries"      ? a.action : null;
const matchSearch      = (a: AppAction): SearchAction      | null => a.tag === "search"       ? a.action : null;
const matchErrors      = (a: AppAction): ErrorsAction      | null => a.tag === "errors"       ? a.action : null;
const matchRuntime     = (a: AppAction): RuntimeAction     | null => a.tag === "runtime"      ? a.action : null;
const matchWindowManager = (a: AppAction): WindowManagerAction | null => a.tag === "windowManager" ? a.action : null;

// ── Initial state ─────────────────────────────────────────────────────────────

export function initialState(): AppState {
  return {
    theme: "dark",
    nav: {
      route: { view: "dashboard" },
      crumbs: crumbsForRoute({ view: "dashboard" }),
      history: [{ view: "dashboard" }],
      historyIdx: 0,
      askContext: null,
    },
    dashboard: initialDashboardState,
    objects: initialObjectsState,
    datawindows: initialDatawindowsState,
    tables: initialTablesState,
    diagrams: initialDiagramsState,
    queries: initialQueriesState,
    search: initialSearchState,
    explore: makeInitialExploreState(),
    errors: initialErrorsState,
    inlineDiagrams: {},
    runtime: initialRuntimeState,
    windowManager: initialWindowManagerState,
  };
}

// ── Combined reducer ──────────────────────────────────────────────────────────

const toNav = (nav: NavigationAction): AppAction => ({ tag: "nav", action: nav });

const _combined = combine<AppState, AppAction, AppEnv>(
  pullback(navReducer,                (s) => s.nav,         matchNav,         (a): AppAction => ({ tag: "nav",         action: a }), (env) => env),
  pullback(dashboardReducer,          (s) => s.dashboard,   matchDashboard,   (a): AppAction => ({ tag: "dashboard",   action: a }), (env) => env),
  pullbackWithNav(exploreReducer,     (s) => s.explore,     matchExplore,     (a): AppAction => ({ tag: "explore",     action: a }), (env) => env, toNav),
  pullbackWithNav(objectsReducer,     (s) => s.objects,     matchObjects,     (a): AppAction => ({ tag: "objects",     action: a }), (env) => env, toNav),
  pullbackWithNav(datawindowsReducer, (s) => s.datawindows, matchDatawindows, (a): AppAction => ({ tag: "datawindows", action: a }), (env) => env, toNav),
  pullbackWithNav(tablesReducer,      (s) => s.tables,      matchTables,      (a): AppAction => ({ tag: "tables",      action: a }), (env) => env, toNav),
  pullbackWithNav(diagramsReducer,    (s) => s.diagrams,    matchDiagrams,    (a): AppAction => ({ tag: "diagrams",    action: a }), (env) => env, toNav),
  pullbackWithNav(queriesReducer,     (s) => s.queries,     matchQueries,     (a): AppAction => ({ tag: "queries",     action: a }), (env) => env, toNav),
  pullbackWithNav(searchReducer,      (s) => s.search,      matchSearch,      (a): AppAction => ({ tag: "search",      action: a }), (env) => env, toNav),
  pullback(errorsReducer,             (s) => s.errors,      matchErrors,      (a): AppAction => ({ tag: "errors",      action: a }), (env) => env),
  pullback(runtimeReducer,            (s) => s.runtime,     matchRuntime,     (a): AppAction => ({ tag: "runtime",     action: a }), (env) => env),
  pullback(windowManagerReducer,      (s) => s.windowManager, matchWindowManager, (a): AppAction => ({ tag: "windowManager", action: a }), () => undefined as void),
);

export function reducer(draft: AppState, action: AppAction, env: AppEnv): Effect<AppAction> | null {
  if (action.tag === "theme") {
    switch (action.action.tag) {
    case "load":
      return env.loadTheme().map((theme): AppAction => ({ tag: "theme", action: { tag: "loaded", theme } }));
    case "loaded":
      draft.theme = action.action.theme;
      return env.applyTheme(action.action.theme);
    case "toggle": {
      draft.theme = draft.theme === "dark" ? "light" : "dark";
      return env.applyTheme(draft.theme);
    }
    }
  }
  if (action.tag === "inlineDiagram") {
    const { action: ia } = action;
    switch (ia.tag) {
    case "request": {
      const existing = draft.inlineDiagrams[ia.key];
      if (existing?.loading) return null;
      draft.inlineDiagrams[ia.key] = { svg: null, loading: true, error: null };
      return env.getDiagram(ia.kind, ia.params)
        .map((svg): AppAction => ({ tag: "inlineDiagram", action: { tag: "loaded", key: ia.key, svg } }))
        .catch((e): AppAction => ({ tag: "inlineDiagram", action: { tag: "error", key: ia.key, error: String(e) } }));
    }
    case "loaded": {
      draft.inlineDiagrams[ia.key] = { svg: ia.svg, loading: false, error: null };
      return null;
    }
    case "error": {
      draft.inlineDiagrams[ia.key] = { svg: null, loading: false, error: ia.error };
      return null;
    }
    }
  }
  return _combined(draft, action, env);
}
