// core.ts — Re-export shim. All logic moved to core/ and app/ subdirectories.

export { Effect } from "./core/effect.js";
export { pullback, combine } from "./core/reducer.js";
export type { Reducer } from "./core/reducer.js";
export { useSnapshot, scope, createStore } from "./core/store.js";
export type { Store, ScopedStore } from "./core/store.js";
export { AppEnv, initialState, reducer } from "./app/reducer.js";
export type { AppEnv as Env } from "./app/reducer.js";

// Re-export types that existing code imports from core.ts
import type { AppState } from "./app/state.js";
import type { AppAction, Dispatch } from "./app/actions.js";

export type { AppState, AppAction, Dispatch };

// ── ApiClient interface (for api-client.ts) ──────────────────────────────────

import type {
  StatsResponse, ListObjectsResponse, ObjectDetailResponse, ObjectSourceResponse,
  ProcedureDetailResponse, DwDetailResponse, SearchResponse, QueryDef, QueryResult,
  ExploreTreeResponse, DwExploreDetail, ExploreProcDetail, TableSummary, TableDetail,
} from "./types/api.js";

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
