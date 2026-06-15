// core.ts — Pure state management for pb explore.
//
// Architecture:
//   State   — single immutable object (AppState)
//   Action  — discriminated union (AppAction)
//   Effect  — class wrapping (send: (a: A) => void) => Promise<void>; supports .map()
//   Reducer — (state, action, env) -> [newState, Effect<AppAction> | null]

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
  ExploreProcDetail,
  QueryDef,
  TableSummary,
  TableDetail,
} from "./types/api.js";

// ── Node ID helpers ──────────────────────────────────────────────────────────

function libId(name: string): string { return `lib:${name}`; }
function objId(lib: string, name: string): string { return `obj:${lib}:${name}`; }
function errMsg(e: unknown): string { return e instanceof Error ? e.message : String(e); }

// ── Effect ───────────────────────────────────────────────────────────────────

type Runner<A> = (send: (a: A) => void) => Promise<void>;

export class Effect<A> {
  private constructor(private readonly runner: Runner<A>) {}

  /** An effect that does nothing. */
  static none<A>(): Effect<A> {
    return new Effect(() => Promise.resolve());
  }

  /** An effect that immediately sends a single value. Useful in tests. */
  static send<A>(a: A): Effect<A> {
    return new Effect(send => { send(a); return Promise.resolve(); });
  }

  /** Lift a promise thunk; errors propagate (store catches unhandled rejections). */
  static fromPromise<A>(thunk: () => Promise<A>): Effect<A> {
    return new Effect(send => thunk().then(a => { send(a); }));
  }

  /** Run all effects concurrently; each sends into the same channel. */
  static merge<A>(...effects: Effect<A>[]): Effect<A> {
    return new Effect(send =>
      Promise.all(effects.map(e => e.runner(send))).then(() => {})
    );
  }

  map<B>(f: (a: A) => B): Effect<B> {
    return new Effect(send => this.runner(a => send(f(a))));
  }

  /** Convert a rejected promise into a sent value rather than a thrown error. */
  catch(onReject: (e: unknown) => A): Effect<A> {
    return new Effect(send =>
      this.runner(send).catch(e => { send(onReject(e)); })
    );
  }

  /** @internal — called by the store. */
  execute(send: (a: A) => void): Promise<void> {
    return this.runner(send);
  }
}

// ── Types ────────────────────────────────────────────────────────────────────

export type Dispatch = (action: AppAction) => void;
export type GetState = () => AppState;
export type Reducer = (state: AppState, action: AppAction, env: Env) => [AppState, Effect<AppAction> | null];

// ApiClient — Promise-based adapter implemented in api-client.ts.
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
  getQueries(): Promise<{ queries: QueryDef[] }>;
  runQuery(name: string, params: Record<string, string>): Promise<QueryResult>;
  getExploreTree(): Promise<ExploreTreeResponse>;
  getExploreProcedure(objectName: string, procName: string): Promise<ExploreProcDetail>;
  getExploreDatawindow(name: string): Promise<DwExploreDetail>;
  getTables(): Promise<TableSummary[]>;
  getTableDetail(name: string): Promise<TableDetail>;
}

// Env — Effect-based environment. All effects in the reducer are produced via
// calls to env. Tests replace individual methods via object spread.
export interface Env {
  getStats(): Effect<StatsResponse>;
  getObjects(params: Record<string, string | number>): Effect<ListObjectsResponse>;
  getObject(name: string): Effect<ObjectDetailResponse>;
  getObjectSource(name: string): Effect<ObjectSourceResponse>;
  getAllObjects(): Effect<ListObjectsResponse>;
  getProcedure(obj: string, proc: string): Effect<ProcedureDetailResponse>;
  search(q: string): Effect<SearchResponse>;
  getDW(name: string): Effect<DwDetailResponse>;
  getDiagram(kind: string, params: Record<string, string | number>): Effect<string>;
  getQueries(): Effect<{ queries: QueryDef[] }>;
  runQuery(name: string, params: Record<string, string>): Effect<QueryResult>;
  getExploreTree(): Effect<ExploreTreeResponse>;
  getExploreProcedure(objectName: string, procName: string): Effect<ExploreProcDetail>;
  getExploreDatawindow(name: string): Effect<DwExploreDetail>;
  getTables(): Effect<TableSummary[]>;
  getTableDetail(name: string): Effect<TableDetail>;
}

// ── State ────────────────────────────────────────────────────────────────────

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
      selectedProc: null,
      selectedDw: null,
      procCache: {},
      dwCache: {},
      loading: false,
      activeTab: "source" as const,
      treeFilter: "",
      highlightedLine: null,
      leftTab: "objects" as const,
      tables: {
        items: [],
        filter: "",
        selected: null,
        detail: null,
        loading: false,
        detailLoading: false,
      },
    },
  };
}

// ── Reducer ──────────────────────────────────────────────────────────────────

export function reducer(state: AppState, action: AppAction, env: Env): [AppState, Effect<AppAction> | null] {
  switch (action.type) {

  // Navigation
  case "NAVIGATE":
    return [{ ...state, view: action.view }, null];

  // Stats
  case "STATS_LOAD":
    return [state, env.getStats()
      .map((stats): AppAction => ({ type: "STATS_LOADED", stats }))];
  case "STATS_LOADED":
    return [{ ...state, stats: action.stats }, null];

  // Objects
  case "OBJECTS_SEARCH": {
    const p = { q: action.q, kind: state.objects.kind, sort: state.objects.sort, order: state.objects.order, limit: 100, offset: 0 };
    return [
      { ...state, objects: { ...state.objects, q: action.q, offset: 0, loading: true } },
      env.getObjects(p).map((data): AppAction => ({ type: "OBJECTS_LOADED", data })),
    ];
  }

  case "OBJECTS_FILTER_KIND": {
    const p = { q: state.objects.q, kind: action.kind, sort: state.objects.sort, order: state.objects.order, limit: 100, offset: 0 };
    return [
      { ...state, objects: { ...state.objects, kind: action.kind, offset: 0, loading: true } },
      env.getObjects(p).map((data): AppAction => ({ type: "OBJECTS_LOADED", data })),
    ];
  }

  case "OBJECTS_SORT": {
    const order = state.objects.sort === action.col
      ? (state.objects.order === "asc" ? "desc" : "asc")
      : "asc";
    const p = { q: state.objects.q, kind: state.objects.kind, sort: action.col, order, limit: 100, offset: 0 };
    return [
      { ...state, objects: { ...state.objects, sort: action.col, order, offset: 0, loading: true } },
      env.getObjects(p).map((data): AppAction => ({ type: "OBJECTS_LOADED", data })),
    ];
  }

  case "OBJECTS_PAGE": {
    const p = { q: state.objects.q, kind: state.objects.kind, sort: state.objects.sort, order: state.objects.order, limit: 100, offset: action.offset };
    return [
      { ...state, objects: { ...state.objects, offset: action.offset, loading: true } },
      env.getObjects(p).map((data): AppAction => ({ type: "OBJECTS_LOADED", data })),
    ];
  }

  case "OBJECTS_LOADED":
    return [{
      ...state,
      objects: { ...state.objects, items: action.data.items, total: action.data.total, loading: false },
    }, null];

  // Object detail
  case "OBJECT_SELECTED":
    return [
      { ...state, objectDetail: null, sourceDetail: null, view: "objectDetail" },
      Effect.merge<AppAction>(
        env.getObject(action.name)
          .map((data): AppAction => ({ type: "OBJECT_LOADED", data }))
          .catch((e): AppAction => ({ type: "OBJECT_LOAD_ERROR", error: errMsg(e) })),
        env.getObjectSource(action.name)
          .map((data): AppAction => ({ type: "SOURCE_LOADED", data }))
          .catch((e): AppAction => ({ type: "SOURCE_ERROR", error: errMsg(e) })),
      ),
    ];
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
    return [
      { ...state, procedureDetail: null, view: "procedureDetail" },
      env.getProcedure(action.objectName, action.procName)
        .map((data): AppAction => ({ type: "PROCEDURE_LOADED", data }))
        .catch((e): AppAction => ({ type: "PROCEDURE_LOAD_ERROR", error: errMsg(e) })),
    ];
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
  case "DW_SEARCH": {
    const p = { q: action.q, kind: "datawindow", limit: 200 };
    return [
      { ...state, datawindows: { ...state.datawindows, q: action.q, loading: true } },
      env.getObjects(p).map((data): AppAction => ({ type: "DW_LOADED", data })),
    ];
  }

  case "DW_LOADED":
    return [{
      ...state,
      datawindows: { ...state.datawindows, items: action.data.items, total: action.data.total, loading: false },
    }, null];

  case "DW_SELECTED":
    return [
      { ...state, dwDetail: null, view: "dwDetail" },
      env.getDW(action.name)
        .map((data): AppAction => ({ type: "DW_LOADED_DETAIL", data }))
        .catch((e): AppAction => ({ type: "DW_LOAD_ERROR", error: errMsg(e) })),
    ];
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
    return [{ ...state, diagrams: { ...state.diagrams, params: action.params } }, null];

  case "DIAGRAM_GENERATE":
    return [
      { ...state, diagrams: { ...state.diagrams, loading: true } },
      env.getDiagram(state.diagrams.active, state.diagrams.params)
        .map((svg): AppAction => ({ type: "DIAGRAM_LOADED", svg }))
        .catch((e): AppAction => ({ type: "DIAGRAM_ERROR", error: errMsg(e) })),
    ];
  case "DIAGRAM_LOADED":
    return [{ ...state, diagrams: { ...state.diagrams, svg: action.svg, loading: false } }, null];
  case "DIAGRAM_ERROR":
    return [{ ...state, diagrams: { ...state.diagrams, svg: null, loading: false, error: action.error } }, null];

  // Queries
  case "QUERIES_LOAD":
    return [
      { ...state, queries: { ...state.queries, loading: true } },
      env.getQueries().map((data): AppAction => ({ type: "QUERIES_LOADED", items: data.queries })),
    ];
  case "QUERIES_LOADED":
    return [{ ...state, queries: { ...state.queries, items: action.items, loading: false } }, null];

  case "QUERY_RUN":
    return [
      { ...state, queries: { ...state.queries, results: null, resultsName: action.name } },
      env.runQuery(action.name, action.params)
        .map((data): AppAction => ({ type: "QUERY_LOADED", data }))
        .catch((e): AppAction => ({ type: "QUERY_ERROR", error: errMsg(e) })),
    ];
  case "QUERY_LOADED":
    return [{ ...state, queries: { ...state.queries, results: action.data, loading: false } }, null];
  case "QUERY_ERROR":
    return [{ ...state, queries: { ...state.queries, results: { error: action.error }, loading: false } }, null];

  // Search
  case "SEARCH_TERM": {
    const next = { ...state, search: { ...state.search, term: action.term } };
    if (action.term.length < 2) return [next, null];
    return [next, env.search(action.term).map((data): AppAction => ({ type: "SEARCH_LOADED", data }))];
  }

  case "SEARCH_LOADED":
    return [{ ...state, search: { ...state.search, results: action.data, loading: false } }, null];

  // Explore
  case "EXPLORE_LOAD":
    return [
      { ...state, explore: { ...state.explore, loading: true } },
      env.getExploreTree()
        .map((data): AppAction => ({ type: "EXPLORE_LOADED", data }))
        .catch((): AppAction => ({ type: "EXPLORE_LOADED", data: { libraries: [] } })),
    ];

  case "EXPLORE_LOADED":
    return [{ ...state, explore: { ...state.explore, libraries: action.data.libraries, loading: false } }, null];

  case "EXPLORE_TOGGLE": {
    const expanded = new Set(state.explore.expandedNodes);
    if (expanded.has(action.nodeId)) { expanded.delete(action.nodeId); } else { expanded.add(action.nodeId); }
    return [{ ...state, explore: { ...state.explore, expandedNodes: expanded } }, null];
  }

  case "EXPLORE_PROC_SELECT": {
    const next = { ...state, explore: { ...state.explore, selectedProc: action.nodeId, selectedDw: null, activeTab: "source" as const, highlightedLine: null } };
    if (!(action.nodeId in state.explore.procCache)) {
      return [next, env.getExploreProcedure(action.objectName, action.procName)
        .map((data): AppAction => ({ type: "EXPLORE_PROC_LOADED", nodeId: action.nodeId, data }))
        .catch((e): AppAction => ({ type: "EXPLORE_PROC_ERROR", nodeId: action.nodeId, error: String(e) }))];
    }
    return [next, null];
  }

  case "EXPLORE_PROC_LOADED":
    return [{ ...state, explore: { ...state.explore, procCache: { ...state.explore.procCache, [action.nodeId]: action.data } } }, null];

  case "EXPLORE_PROC_ERROR":
    return [{ ...state, explore: { ...state.explore, procCache: { ...state.explore.procCache, [action.nodeId]: { error: action.error } } } }, null];

  case "EXPLORE_EXPAND_ALL": {
    const expanded = new Set<string>();
    for (const lib of state.explore.libraries) {
      expanded.add(libId(lib.name));
      for (const obj of lib.objects) { expanded.add(objId(lib.name, obj.name)); }
    }
    return [{ ...state, explore: { ...state.explore, expandedNodes: expanded } }, null];
  }

  case "EXPLORE_COLLAPSE_ALL":
    return [{ ...state, explore: { ...state.explore, expandedNodes: new Set<string>() } }, null];

  case "EXPLORE_DW_SELECT": {
    const next = { ...state, explore: { ...state.explore, selectedDw: action.nodeId, selectedProc: null, highlightedLine: null } };
    if (!(action.nodeId in state.explore.dwCache)) {
      return [next, env.getExploreDatawindow(action.dwName)
        .map((data): AppAction => ({ type: "EXPLORE_DW_LOADED", nodeId: action.nodeId, data }))
        .catch((e): AppAction => ({ type: "EXPLORE_DW_ERROR", nodeId: action.nodeId, error: String(e) }))];
    }
    return [next, null];
  }

  case "EXPLORE_DW_LOADED":
    return [{ ...state, explore: { ...state.explore, dwCache: { ...state.explore.dwCache, [action.nodeId]: action.data } } }, null];

  case "EXPLORE_DW_ERROR":
    return [{ ...state, explore: { ...state.explore, dwCache: { ...state.explore.dwCache, [action.nodeId]: { error: action.error } } } }, null];

  case "EXPLORE_TAB":
    return [{ ...state, explore: { ...state.explore, activeTab: action.tab } }, null];

  case "EXPLORE_FILTER":
    return [{ ...state, explore: { ...state.explore, treeFilter: action.q } }, null];

  case "EXPLORE_HIGHLIGHT_LINE":
    return [{ ...state, explore: { ...state.explore, highlightedLine: action.line } }, null];

  // Tables browser
  case "EXPLORE_LEFT_TAB": {
    const clearSel = action.tab === "tables"
      ? { selectedProc: null, selectedDw: null }
      : { tables: { ...state.explore.tables, selected: null, detail: null } };
    const next = { ...state, explore: { ...state.explore, leftTab: action.tab, ...clearSel } };
    if (action.tab === "tables" && state.explore.tables.items.length === 0 && !state.explore.tables.loading) {
      return [{ ...next, explore: { ...next.explore, tables: { ...next.explore.tables, loading: true } } },
        env.getTables()
          .map((items): AppAction => ({ type: "TABLES_LOADED", items }))
          .catch((): AppAction => ({ type: "TABLES_LOADED", items: [] }))];
    }
    return [next, null];
  }

  case "TABLES_LOAD":
    return [
      { ...state, explore: { ...state.explore, tables: { ...state.explore.tables, loading: true } } },
      env.getTables()
        .map((items): AppAction => ({ type: "TABLES_LOADED", items }))
        .catch((): AppAction => ({ type: "TABLES_LOADED", items: [] })),
    ];

  case "TABLES_LOADED":
    return [{ ...state, explore: { ...state.explore, tables: { ...state.explore.tables, items: action.items, loading: false } } }, null];

  case "TABLES_FILTER":
    return [{ ...state, explore: { ...state.explore, tables: { ...state.explore.tables, filter: action.q } } }, null];

  case "TABLE_SELECT":
    return [
      { ...state, explore: { ...state.explore, selectedDw: null, selectedProc: null, tables: { ...state.explore.tables, selected: action.tableName, detail: null, detailLoading: true } } },
      env.getTableDetail(action.tableName)
        .map((detail): AppAction => ({ type: "TABLE_DETAIL_LOADED", tableName: action.tableName, detail }))
        .catch((e): AppAction => ({ type: "TABLE_DETAIL_ERROR", tableName: action.tableName, error: errMsg(e) })),
    ];

  case "TABLE_DETAIL_LOADED":
    return [{ ...state, explore: { ...state.explore, tables: { ...state.explore.tables, detail: action.detail, detailLoading: false } } }, null];

  case "TABLE_DETAIL_ERROR":
    return [{ ...state, explore: { ...state.explore, tables: { ...state.explore.tables, detail: { error: action.error }, detailLoading: false } } }, null];

  default:
    return [state, null];
  }
}
