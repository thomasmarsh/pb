// api-client.ts — Typed fetch wrapper for the pb explore REST API.

import type {
  ListObjectsResponse,
  ObjectDetailResponse,
  ObjectSourceResponse,
  ProcedureDetailResponse,
  DwDetailResponse,
  SearchResponse,
  StatsResponse,
  QueryDef,
  QueryResult,
  ExploreTreeResponse,
  DwExploreDetail,
  ExploreProcDetail,
  TableSummary,
  TableDetail,
} from "./types/api.js";
import { Effect } from "./core/effect.js";
import type { AppEnv as Env } from "./app/reducer.js";

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

function apiParams(obj: Record<string, string | number>): string {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(obj)) {
    if (v !== "" && v !== null && v !== undefined) p.set(k, String(v));
  }
  return p.toString();
}

async function fetchJson<T>(url: string): Promise<T> {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`API ${r.status}`);
  return r.json() as Promise<T>;
}

export function createEnv(api: ApiClient): Env {
  const lift = <T>(thunk: () => Promise<T>): Effect<T> =>
    Effect.fromPromise(thunk);
  return {
    getStats: () => lift(() => api.getStats()),
    getObjects: (p) => lift(() => api.getObjects(p)),
    getObject: (n) => lift(() => api.getObject(n)),
    getObjectSource: (n) => lift(() => api.getObjectSource(n)),
    getAllObjects: () => lift(() => api.getAllObjects()),
    getProcedure: (o, p) => lift(() => api.getProcedure(o, p)),
    search: (q) => lift(() => api.search(q)),
    getDW: (n) => lift(() => api.getDW(n)),
    getDiagram: (k, p) => lift(() => api.getDiagram(k, p)),
    getQueries: () => lift(() => api.getQueries()),
    runQuery: (n, p) => lift(() => api.runQuery(n, p)),
    getExploreTree: () => lift(() => api.getExploreTree()),
    getExploreProcedure: (o, p) => lift(() => api.getExploreProcedure(o, p)),
    getExploreDatawindow: (n) => lift(() => api.getExploreDatawindow(n)),
    getTables: () => lift(() => api.getTables()),
    getTableDetail: (n) => lift(() => api.getTableDetail(n)),
  };
}

export function createApiClient(): ApiClient {
  return {
    async getStats(): Promise<StatsResponse> {
      return fetchJson("/api/stats");
    },

    async getObjects(
      params: Record<string, string | number>,
    ): Promise<ListObjectsResponse> {
      return fetchJson("/api/objects?" + apiParams(params));
    },

    async getObject(name: string): Promise<ObjectDetailResponse> {
      return fetchJson("/api/objects/" + encodeURIComponent(name));
    },

    async getObjectSource(name: string): Promise<ObjectSourceResponse> {
      return fetchJson("/api/objects/" + encodeURIComponent(name) + "/source");
    },

    async getAllObjects(): Promise<ListObjectsResponse> {
      return fetchJson("/api/objects?limit=500");
    },

    async getProcedure(
      obj: string,
      proc: string,
    ): Promise<ProcedureDetailResponse> {
      return fetchJson(
        `/api/procedures/${encodeURIComponent(obj)}/${encodeURIComponent(proc)}`,
      );
    },

    async search(q: string): Promise<SearchResponse> {
      return fetchJson("/api/search?q=" + encodeURIComponent(q));
    },

    async getDW(name: string): Promise<DwDetailResponse> {
      return fetchJson("/api/dw/" + encodeURIComponent(name));
    },

    async getDiagram(
      kind: string,
      params: Record<string, string | number>,
    ): Promise<string> {
      const r = await fetch(`/api/diagram/${kind}?` + apiParams(params));
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return r.text();
    },

    async getQueries(): Promise<{ queries: QueryDef[] }> {
      return fetchJson("/api/queries");
    },

    async runQuery(
      name: string,
      params: Record<string, string>,
    ): Promise<QueryResult> {
      return fetchJson(`/api/queries/${name}/run?` + apiParams(params));
    },

    async getExploreTree(): Promise<ExploreTreeResponse> {
      return fetchJson("/api/explore/tree");
    },

    async getExploreProcedure(
      objectName: string,
      procName: string,
    ): Promise<ExploreProcDetail> {
      return fetchJson(
        `/api/explore/procedure/${encodeURIComponent(objectName)}/${encodeURIComponent(procName)}`,
      );
    },

    async getExploreDatawindow(name: string): Promise<DwExploreDetail> {
      return fetchJson(`/api/explore/datawindow/${encodeURIComponent(name)}`);
    },

    async getTables(): Promise<TableSummary[]> {
      return fetchJson("/api/tables");
    },

    async getTableDetail(name: string): Promise<TableDetail> {
      return fetchJson(`/api/tables/${encodeURIComponent(name)}`);
    },
  };
}
