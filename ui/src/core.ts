// core.ts — Pure state management for pb explore.
//
// No DOM, no side effects, no imports except types. Fully testable.
//
// Architecture:
//   State   — single immutable object (AppState)
//   Action  — discriminated union (AppAction)
//   Effect  — (dispatch, getState, env) => Promise<void>
//   Reducer — (state, action) -> [newState, Effect | null]

import type { AppState } from "./types/state.js";
import type { AppAction } from "./types/actions.js";
import type {
  ListObjectsResponse,
  ObjectDetailResponse,
  ObjectSourceResponse,
  ProcedureDetailResponse,
  DwDetailResponse,
  QueryResult,
  SearchResponse,
  StatsResponse,
  ExploreTreeResponse,
  DwExploreDetail,
} from "./types/api.js";
import type { BodyStmt } from "./types/ast.generated.js";

// ── Node ID helpers ──────────────────────────────────────────────────────────

function libId(name: string): string { return `lib:${name}`; }
function objId(lib: string, name: string): string { return `obj:${lib}:${name}`; }

// ── Types ───────────────────────────────────────────────────────────────────

export type Dispatch = (action: AppAction) => void;
export type GetState = () => AppState;
export type Effect = (dispatch: Dispatch, getState: GetState, env: Env) => Promise<void>;
export type ReducerResult = [AppState, Effect | null];
export type Reducer = (state: AppState, action: AppAction) => ReducerResult;

export interface ApiClient {
  getStats(): Promise<StatsResponse>;
  getObjects(params: Record<string, string | number>): Promise<ListObjectsResponse>;
  getObject(name: string): Promise<ObjectDetailResponse>;
  getObjectSource(name: string): Promise<ObjectSourceResponse>;
  getAllObjects(): Promise<ListObjectsResponse>;
  getProcedure(obj: string, proc: string): Promise<ProcedureDetailResponse>;
  search(q: string): Promise<SearchResponse>;
  getDW(name: string): Promise<DwDetailResponse>;
  getDiagram(kind: string, params: Record<string, string | number>): Promise<string>;
  getQueries(): Promise<{ queries: import("./types/api.js").QueryDef[] }>;
  runQuery(name: string, params: Record<string, string>): Promise<QueryResult>;
  getExploreTree(): Promise<ExploreTreeResponse>;
  getExploreProcedure(objectName: string, procName: string): Promise<{ ast: BodyStmt[] | null }>;
  getExploreDatawindow(name: string): Promise<DwExploreDetail>;
}

export interface Env {
  api: ApiClient;
}

// ── State ───────────────────────────────────────────────────────────────────

export function initialState(): AppState {
  return {
    view: "dashboard",
    stats: null,
    objects: {
      items: [], total: 0,
      q: "", kind: "", sort: "name", order: "asc",
      offset: 0, loading: false,
    },
    objectDetail: null,
    sourceDetail: null,
    procedureDetail: null,
    allObjects: [],
    datawindows: { items: [], total: 0, q: "", loading: false },
    dwDetail: null,
    diagrams: { active: "inheritance", svg: null, loading: false, params: {} },
    queries: { items: [], results: null, resultsName: "", loading: false },
    search: { term: "", results: null, loading: false },
    explore: {
      libraries: [],
      expandedNodes: new Set<string>(),
      selectedNode: null,
      astCache: {},
      dwCache: {},
      loading: false,
    },
  };
}

// ── Effects ─────────────────────────────────────────────────────────────────

export async function fetchObjectsEffect(dispatch: Dispatch, getState: GetState, env: Env): Promise<void> {
  const s = getState();
  const p = {
    q: s.objects.q, kind: s.objects.kind,
    sort: s.objects.sort, order: s.objects.order,
    limit: 100, offset: s.objects.offset,
  };
  try {
    const data = await env.api.getObjects(p);
    dispatch({ type: "OBJECTS_LOADED", data });
  } catch (e) { console.error("objects fetch failed:", e); }
}

export async function fetchDWListEffect(dispatch: Dispatch, getState: GetState, env: Env): Promise<void> {
  const s = getState();
  const p = { q: s.datawindows.q, kind: "datawindow", limit: 200 };
  try {
    const data = await env.api.getObjects(p);
    dispatch({ type: "DW_LOADED", data });
  } catch (e) { console.error("dw fetch failed:", e); }
}

export async function doSearchEffect(dispatch: Dispatch, getState: GetState, env: Env): Promise<void> {
  const s = getState();
  const q = s.search.term;
  if (!q || q.length < 2) return;
  try {
    const data = await env.api.search(q);
    dispatch({ type: "SEARCH_LOADED", data });
  } catch (e) { console.error("search failed:", e); }
}

function asyncFetch<T>(
  apiCall: (api: ApiClient) => Promise<T>,
  loadedType: string,
  errorType: string,
): Effect {
  return async (dispatch, _getState, env) => {
    try {
      const data = await apiCall(env.api);
      dispatch({ type: loadedType, data } as AppAction);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      dispatch({ type: errorType, error: msg } as AppAction);
    }
  };
}

// ── Reducer ─────────────────────────────────────────────────────────────────

export function reducer(state: AppState, action: AppAction): ReducerResult {
  switch (action.type) {

  // Navigation
  case "NAVIGATE":
    return [{ ...state, view: action.view }, null];

  // Stats
  case "STATS_LOAD":
    return [state, async (dispatch, _getState, env) => {
      try {
        const stats = await env.api.getStats();
        dispatch({ type: "STATS_LOADED", stats });
      } catch (e) { console.error("stats load failed:", e); }
    }];
  case "STATS_LOADED":
    return [{ ...state, stats: action.stats }, null];

  // Objects
  case "OBJECTS_SEARCH":
    return [{
      ...state,
      objects: { ...state.objects, q: action.q, offset: 0, loading: true },
    }, fetchObjectsEffect];

  case "OBJECTS_FILTER_KIND":
    return [{
      ...state,
      objects: { ...state.objects, kind: action.kind, offset: 0, loading: true },
    }, fetchObjectsEffect];

  case "OBJECTS_SORT":
    return [{
      ...state,
      objects: {
        ...state.objects,
        sort: action.col,
        order: state.objects.sort === action.col
          ? (state.objects.order === "asc" ? "desc" : "asc")
          : "asc",
        offset: 0, loading: true,
      },
    }, fetchObjectsEffect];

  case "OBJECTS_PAGE":
    return [{
      ...state,
      objects: { ...state.objects, offset: action.offset, loading: true },
    }, fetchObjectsEffect];

  case "OBJECTS_LOADED":
    return [{
      ...state,
      objects: { ...state.objects, items: action.data.items, total: action.data.total, loading: false },
    }, null];

  // Object detail
  case "OBJECT_SELECTED":
    return [{ ...state, objectDetail: null, sourceDetail: null, view: "objectDetail" }, async (dispatch, _getState, env) => {
      try {
        const [data, source] = await Promise.all([
          env.api.getObject(action.name),
          env.api.getObjectSource(action.name),
        ]);
        dispatch({ type: "OBJECT_LOADED", data });
        dispatch({ type: "SOURCE_LOADED", data: source });
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        dispatch({ type: "OBJECT_LOAD_ERROR", error: msg });
      }
    }];
  case "OBJECT_LOADED":
    return [{ ...state, objectDetail: { ...action.data, loading: false } }, null];
  case "OBJECT_LOAD_ERROR":
    return [{ ...state, objectDetail: { error: action.error } }, null];

  // Source
  case "SOURCE_LOADED":
    return [{ ...state, sourceDetail: { ...action.data, loading: false } }, null];
  case "SOURCE_ERROR":
    return [{ ...state, sourceDetail: { error: action.error } }, null];

  // All objects preload
  case "ALL_OBJECTS_LOADED":
    return [{ ...state, allObjects: action.data }, null];

  // Procedure detail
  case "PROCEDURE_SELECTED":
    return [{ ...state, procedureDetail: null, view: "procedureDetail" },
      asyncFetch(
        api => api.getProcedure(action.objectName, action.procName),
        "PROCEDURE_LOADED", "PROCEDURE_LOAD_ERROR",
      )];
  case "PROCEDURE_LOADED":
    return [{ ...state, procedureDetail: { ...action.data, activeTab: "original", loading: false } }, null];
  case "PROCEDURE_LOAD_ERROR":
    return [{ ...state, procedureDetail: { error: action.error } }, null];
  case "PROCEDURE_TAB":
    return [{
      ...state,
      procedureDetail: state.procedureDetail
        ? { ...state.procedureDetail, activeTab: action.tab }
        : null,
    }, null];

  // DataWindows
  case "DW_SEARCH":
    return [{
      ...state,
      datawindows: { ...state.datawindows, q: action.q, loading: true },
    }, fetchDWListEffect];

  case "DW_LOADED":
    return [{
      ...state,
      datawindows: { ...state.datawindows, items: action.data.items, total: action.data.total, loading: false },
    }, null];

  case "DW_SELECTED":
    return [{ ...state, dwDetail: null, view: "dwDetail" },
      asyncFetch(api => api.getDW(action.name), "DW_LOADED_DETAIL", "DW_LOAD_ERROR")];
  case "DW_LOADED_DETAIL":
    return [{ ...state, dwDetail: { ...action.data, loading: false } }, null];
  case "DW_LOAD_ERROR":
    return [{ ...state, dwDetail: { error: action.error } }, null];

  // Diagrams
  case "DIAGRAM_SELECT":
    return [{
      ...state,
      diagrams: { ...state.diagrams, active: action.kind, svg: null, loading: false },
    }, null];

  case "DIAGRAM_PARAMS":
    return [{
      ...state,
      diagrams: { ...state.diagrams, params: action.params },
    }, null];

  case "DIAGRAM_GENERATE":
    return [{ ...state, diagrams: { ...state.diagrams, loading: true } },
      async (dispatch, getState, env) => {
        try {
          const s = getState();
          const kind = s.diagrams.active;
          const svg = await env.api.getDiagram(kind, s.diagrams.params);
          dispatch({ type: "DIAGRAM_LOADED", svg });
        } catch (e) {
          const msg = e instanceof Error ? e.message : String(e);
          dispatch({ type: "DIAGRAM_ERROR", error: msg });
        }
      }];
  case "DIAGRAM_LOADED":
    return [{ ...state, diagrams: { ...state.diagrams, svg: action.svg, loading: false } }, null];
  case "DIAGRAM_ERROR":
    return [{ ...state, diagrams: { ...state.diagrams, svg: null, loading: false, error: action.error } }, null];

  // Queries
  case "QUERIES_LOAD":
    return [{ ...state, queries: { ...state.queries, loading: true } }, async (dispatch, _getState, env) => {
      try {
        const data = await env.api.getQueries();
        dispatch({ type: "QUERIES_LOADED", items: data.queries });
      } catch (e) { console.error("queries load failed:", e); }
    }];
  case "QUERIES_LOADED":
    return [{ ...state, queries: { ...state.queries, items: action.items, loading: false } }, null];

  case "QUERY_RUN":
    return [{ ...state, queries: { ...state.queries, results: null, resultsName: action.name } },
      asyncFetch(api => api.runQuery(action.name, action.params), "QUERY_LOADED", "QUERY_ERROR")];
  case "QUERY_LOADED":
    return [{ ...state, queries: { ...state.queries, results: action.data, loading: false } }, null];
  case "QUERY_ERROR":
    return [{ ...state, queries: { ...state.queries, results: { error: action.error }, loading: false } }, null];

  // Search
  case "SEARCH_TERM":
    return [{
      ...state,
      search: { ...state.search, term: action.term },
    }, action.term.length >= 2 ? doSearchEffect : null];

  case "SEARCH_LOADED":
    return [{ ...state, search: { ...state.search, results: action.data, loading: false } }, null];

  // Explore
  case "EXPLORE_LOAD":
    return [{ ...state, explore: { ...state.explore, loading: true } },
      async (dispatch, _getState, env) => {
        try {
          const data = await env.api.getExploreTree();
          dispatch({ type: "EXPLORE_LOADED", data });
        } catch (e) {
          console.error("explore tree load failed:", e);
          dispatch({ type: "EXPLORE_LOADED", data: { libraries: [] } });
        }
      }];

  case "EXPLORE_LOADED":
    return [{ ...state, explore: { ...state.explore, libraries: action.data.libraries, loading: false } }, null];

  case "EXPLORE_TOGGLE": {
    const expanded = new Set(state.explore.expandedNodes);
    if (expanded.has(action.nodeId)) {
      expanded.delete(action.nodeId);
    } else {
      expanded.add(action.nodeId);
    }
    return [{ ...state, explore: { ...state.explore, expandedNodes: expanded } }, null];
  }

  case "EXPLORE_SELECT":
    return [{ ...state, explore: { ...state.explore, selectedNode: action.nodeId } }, null];

  case "EXPLORE_PROC_EXPAND": {
    const expanded = new Set(state.explore.expandedNodes);
    const wasExpanded = expanded.has(action.nodeId);
    if (wasExpanded) {
      expanded.delete(action.nodeId);
    } else {
      expanded.add(action.nodeId);
    }
    const next = { ...state, explore: { ...state.explore, expandedNodes: expanded } };
    const alreadyCached = action.nodeId in state.explore.astCache;
    if (!wasExpanded && !alreadyCached) {
      return [next, async (dispatch, _getState, env) => {
        try {
          const data = await env.api.getExploreProcedure(action.objectName, action.procName);
          dispatch({ type: "EXPLORE_AST_LOADED", nodeId: action.nodeId, ast: data.ast });
        } catch (e) {
          dispatch({ type: "EXPLORE_AST_ERROR", nodeId: action.nodeId, error: String(e) });
        }
      }];
    }
    return [next, null];
  }

  case "EXPLORE_AST_LOADED": {
    const cache = { ...state.explore.astCache, [action.nodeId]: action.ast };
    return [{ ...state, explore: { ...state.explore, astCache: cache } }, null];
  }

  case "EXPLORE_AST_ERROR":
    return [{ ...state, explore: { ...state.explore, astCache: { ...state.explore.astCache, [action.nodeId]: { error: action.error } } } }, null];

  case "EXPLORE_EXPAND_ALL": {
    const expanded = new Set<string>();
    for (const lib of state.explore.libraries) {
      expanded.add(libId(lib.name));
      for (const obj of lib.objects) {
        expanded.add(objId(lib.name, obj.name));
      }
    }
    return [{ ...state, explore: { ...state.explore, expandedNodes: expanded } }, null];
  }

  case "EXPLORE_COLLAPSE_ALL":
    return [{ ...state, explore: { ...state.explore, expandedNodes: new Set<string>() } }, null];

  case "EXPLORE_DW_EXPAND": {
    const expanded = new Set(state.explore.expandedNodes);
    const wasExpanded = expanded.has(action.nodeId);
    if (wasExpanded) {
      expanded.delete(action.nodeId);
    } else {
      expanded.add(action.nodeId);
    }
    const next = { ...state, explore: { ...state.explore, expandedNodes: expanded } };
    const alreadyCached = action.nodeId in state.explore.dwCache;
    if (!wasExpanded && !alreadyCached) {
      return [next, async (dispatch, _getState, env) => {
        try {
          const data = await env.api.getExploreDatawindow(action.dwName);
          dispatch({ type: "EXPLORE_DW_LOADED", nodeId: action.nodeId, data });
        } catch (e) {
          dispatch({ type: "EXPLORE_DW_ERROR", nodeId: action.nodeId, error: String(e) });
        }
      }];
    }
    return [next, null];
  }

  case "EXPLORE_DW_LOADED":
    return [{ ...state, explore: { ...state.explore, dwCache: { ...state.explore.dwCache, [action.nodeId]: action.data } } }, null];

  case "EXPLORE_DW_ERROR":
    return [{ ...state, explore: { ...state.explore, dwCache: { ...state.explore.dwCache, [action.nodeId]: { error: action.error } } } }, null];

  default:
    return [state, null];
  }
}
