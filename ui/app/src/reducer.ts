// app/reducer.ts — App-level reducer: combines all feature reducers.
// Owns initialState() factory, the top-level reducer, and all app↔feature lenses.

import { pullback, pullbackWithNav, combine, Effect, jobPollReduce, initialJobPollState, type JobPollEnv, type JobSubmitResult, type JobPollResult } from "@pb/core";
import type { AppState } from "./state.js";
import type { AppAction } from "./actions.js";
import type { CfgDiagramResponse, ExplainPseudocodeResponse } from "@pb/platform";

import { navReducer, type NavEnv, dashboardReducer, type DashboardEnv, initialDashboardState, exploreReducer, makeInitialExploreState, type ExploreEnv, objectsReducer, type ObjectsEnv, initialObjectsState, datawindowsReducer, type DatawindowsEnv, initialDatawindowsState, tablesReducer, type TablesEnv, initialTablesState, diagramsReducer, type DiagramsEnv, initialDiagramsState, queriesReducer, type QueriesEnv, initialQueriesState, searchReducer, type SearchEnv, initialSearchState, diagnosticsReducer, type DiagnosticsEnv, initialDiagnosticsState, analysisReducer, type AnalysisEnv, initialAnalysisState, type NavigationAction, type ExploreAction, type ObjectsAction, type DatawindowsAction, type TablesAction, type DiagramsAction, type QueriesAction, type SearchAction, type DiagnosticsAction, type AnalysisAction } from "@pb/platform";
import { runtimeReducer, type RuntimeEnv, initialRuntimeState, windowManagerReducer, initialWindowManagerState, launchReducer, initialLaunchState, type LaunchAction, type WindowManagerAction } from "@pb/windowing";

import { crumbsForRoute } from "@pb/platform";
import type { DashboardAction } from "@pb/platform";
export type { LaunchAction };
export type { RuntimeAction } from "@pb/windowing";

import type { Theme } from "./state.js";

export type AppEnv = NavEnv & DashboardEnv & ExploreEnv & ObjectsEnv & DatawindowsEnv & TablesEnv & DiagramsEnv & QueriesEnv & SearchEnv & DiagnosticsEnv & AnalysisEnv & ThemeEnv & RuntimeEnv & CfgDiagramEnv & ExplainEnv;

export interface ThemeEnv {
  loadTheme(): Effect<Theme>;
  applyTheme(theme: Theme): Effect<never>;
}

export interface CfgDiagramEnv {
  submitCfgDiagramJob(object: string, proc: string): Effect<JobSubmitResult<CfgDiagramResponse>>;
  pollCfgDiagramJob(jobId: string): Effect<JobPollResult<CfgDiagramResponse>>;
}

export interface ExplainEnv {
  getExplainPseudocode(object: string, proc: string): Effect<ExplainPseudocodeResponse>;
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
const matchDiagnostics  = (a: AppAction): DiagnosticsAction  | null => a.tag === "diagnostics"   ? a.action : null;
const matchAnalysis    = (a: AppAction): AnalysisAction    | null => a.tag === "analysis"     ? a.action : null;
const matchWindowManager = (a: AppAction): WindowManagerAction | null => a.tag === "windowManager" ? a.action : null;
const matchLaunch = (a: AppAction): LaunchAction | null => a.tag === "launch" ? a.action : null;

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
    diagnostics: initialDiagnosticsState,
    analysis: initialAnalysisState,
    inlineDiagrams: {},
    cfgDiagrams: {},
    explainPseudocodes: {},
    runtimes: {},
    windowManager: initialWindowManagerState,
    launch: initialLaunchState,
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
  pullback(diagnosticsReducer,         (s) => s.diagnostics,  matchDiagnostics,  (a): AppAction => ({ tag: "diagnostics",  action: a }), (env) => env),
  pullback(analysisReducer,           (s) => s.analysis,    matchAnalysis,    (a): AppAction => ({ tag: "analysis",    action: a }), (env) => env),
  pullback(windowManagerReducer,      (s) => s.windowManager, matchWindowManager, (a): AppAction => ({ tag: "windowManager", action: a }), () => undefined as void),
  pullback(launchReducer,             (s) => s.launch,      matchLaunch,       (a): AppAction => ({ tag: "launch",      action: a }), (env) => ({ getObjectAst: env.getObjectAst })),
);

export function reducer(draft: AppState, action: AppAction, env: AppEnv): Effect<AppAction> | null {
  if (action.tag === "runtime") {
    const { windowId, action: ra } = action;
    if (!draft.runtimes[windowId]) draft.runtimes[windowId] = { ...initialRuntimeState };
    const eff = runtimeReducer(draft.runtimes[windowId]!, ra, env);
    return eff ? eff.map((a): AppAction => ({ tag: "runtime", windowId, action: a })) : null;
  }
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
      if (existing?.job.status === "pending") return null;
      draft.inlineDiagrams[ia.key] = { kind: ia.kind, params: ia.params, job: initialJobPollState<string>() };
      const jobEnv: JobPollEnv<string> = {
        submitJob: () => env.submitDiagramJob(ia.kind, ia.params),
        pollJob: (jobId) => env.pollDiagramJob(jobId),
      };
      const eff = jobPollReduce(draft.inlineDiagrams[ia.key]!.job, { tag: "start" }, jobEnv);
      return eff ? eff.map((a): AppAction => ({ tag: "inlineDiagram", action: { tag: "job", key: ia.key, action: a } })) : null;
    }
    case "job": {
      const entry = draft.inlineDiagrams[ia.key];
      if (!entry) return null;
      const jobEnv: JobPollEnv<string> = {
        submitJob: () => env.submitDiagramJob(entry.kind, entry.params),
        pollJob: (jobId) => env.pollDiagramJob(jobId),
      };
      const eff = jobPollReduce(entry.job, ia.action, jobEnv);
      return eff ? eff.map((a): AppAction => ({ tag: "inlineDiagram", action: { tag: "job", key: ia.key, action: a } })) : null;
    }
    }
  }
  if (action.tag === "cfgDiagram") {
    const { action: ca } = action;
    switch (ca.tag) {
    case "request": {
      const existing = draft.cfgDiagrams[ca.key];
      if (existing?.job.status === "pending") return null;
      draft.cfgDiagrams[ca.key] = { object: ca.object, proc: ca.proc, job: initialJobPollState<CfgDiagramResponse>() };
      const jobEnv: JobPollEnv<CfgDiagramResponse> = {
        submitJob: () => env.submitCfgDiagramJob(ca.object, ca.proc),
        pollJob: (jobId) => env.pollCfgDiagramJob(jobId),
      };
      const eff = jobPollReduce(draft.cfgDiagrams[ca.key]!.job, { tag: "start" }, jobEnv);
      return eff ? eff.map((a): AppAction => ({ tag: "cfgDiagram", action: { tag: "job", key: ca.key, action: a } })) : null;
    }
    case "job": {
      const entry = draft.cfgDiagrams[ca.key];
      if (!entry) return null;
      const jobEnv: JobPollEnv<CfgDiagramResponse> = {
        submitJob: () => env.submitCfgDiagramJob(entry.object, entry.proc),
        pollJob: (jobId) => env.pollCfgDiagramJob(jobId),
      };
      const eff = jobPollReduce(entry.job, ca.action, jobEnv);
      return eff ? eff.map((a): AppAction => ({ tag: "cfgDiagram", action: { tag: "job", key: ca.key, action: a } })) : null;
    }
    }
  }
  if (action.tag === "explain") {
    const { action: ea } = action;
    switch (ea.tag) {
    case "request": {
      const existing = draft.explainPseudocodes[ea.key];
      if (existing && existing.data === null) return null;
      draft.explainPseudocodes[ea.key] = { object: ea.object, proc: ea.proc, data: null };
      return env.getExplainPseudocode(ea.object, ea.proc)
        .map((data): AppAction => ({ tag: "explain", action: { tag: "loaded", key: ea.key, data } }))
        .catch((err): AppAction => ({ tag: "explain", action: { tag: "failed", key: ea.key, error: String(err) } }));
    }
    case "loaded": {
      const entry = draft.explainPseudocodes[ea.key];
      if (!entry) return null;
      entry.data = ea.data;
      return null;
    }
    case "failed": {
      const entry = draft.explainPseudocodes[ea.key];
      if (!entry) return null;
      entry.data = { error: ea.error };
      return null;
    }
    }
  }
  // Launch cascade: when the launch reducer finishes loading a window AST,
  // dispatch open-window (window-manager) + set-ast/run-event (runtime) as
  // follow-up effects so the window appears and its open event executes.
  // Also let _combined handle the action so the launch reducer updates its state.
  if (action.tag === "launch" && action.action.tag === "window-ast-loaded") {
    const { windowName, ast } = action.action;
    const id = `${windowName}-${Date.now()}`;
    const base = _combined(draft, action, env);
    const globals = { ...draft.launch.globals };
    const layoutEffect = env.getObjectLayout(windowName)
      .map((layout): AppAction => ({ tag: "runtime", windowId: id, action: { tag: "layout-loaded", layout } }))
      .catch((): AppAction => ({ tag: "runtime", windowId: id, action: { tag: "layout-loaded", layout: null } }));
    const cascade = Effect.merge<AppAction>(
      Effect.send({ tag: "windowManager", action: { tag: "open-window", id, title: `${windowName}`, runtimeWindowName: windowName } }),
      Effect.send({ tag: "runtime", windowId: id, action: { tag: "set-ast", ast } }),
      Effect.send({ tag: "runtime", windowId: id, action: { tag: "run-event", owner: windowName, event: "open", globals } }),
      layoutEffect,
    );
    return base ? Effect.merge(base, cascade) : cascade;
  }
  return _combined(draft, action, env);
}
