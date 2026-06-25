// api-client.ts — Typed fetch wrapper for the pb explore REST API.

import type {
  ListObjectsResponse,
  ObjectDetailResponse,
  ObjectSourceResponse,
  ProcedureDetailResponse,
  ProcedureListItem,
  DwDetailResponse,
  SearchResponse,
  StatsResponse,
  QueryDef,
  QueryResult,
  ExploreTreeResponse,

  ExploreProcDetail,
  TableSummary,
  TableDetail,
  ErrorListResponse,
} from "../../types/api.js";
import type { DataWindowFile } from "../../types/ast.js";
import type { AstData } from "../../core/interpreter.js";
import type { WindowLayout } from "../../core/layout.js";
import type { SQLResult } from "../../core/sql.js";
import { Effect } from "../../core/effect.js";
import type { AppEnv as Env } from "./reducer.js";
import type { Theme } from "./state.js";
import type { NavigationAction } from "../navigation/types.js";


export interface ApiClient {
  getStats(): Promise<StatsResponse>;
  getObjects(params: Record<string, string | number>): Promise<ListObjectsResponse>;
  getObject(name: string): Promise<ObjectDetailResponse>;
  getObjectSource(name: string): Promise<ObjectSourceResponse>;
  getAllObjects(): Promise<ListObjectsResponse>;
  getProcedure(obj: string, proc: string): Promise<ProcedureDetailResponse>;
  getProcedures(): Promise<ProcedureListItem[]>;
  search(q: string): Promise<SearchResponse>;
  getDW(name: string): Promise<DwDetailResponse>;
  getDwLayout(name: string): Promise<DataWindowFile>;
  getObjectAst(name: string): Promise<AstData>;
  getObjectLayout(name: string): Promise<WindowLayout>;
  getDiagram(kind: string, params: Record<string, string | number>): Promise<string>;
  getQueries(): Promise<{ queries: QueryDef[] }>;
  runQuery(name: string, params: Record<string, string>): Promise<QueryResult>;
  runSql(sql: string): Promise<QueryResult>;
  getExploreTree(): Promise<ExploreTreeResponse>;
  getExploreProcedure(objectName: string, procName: string): Promise<ExploreProcDetail>;
  getExploreDatawindow(name: string): Promise<DwDetailResponse>;
  getTables(): Promise<TableSummary[]>;
  getTableDetail(name: string): Promise<TableDetail>;
  getErrors(params: { kind?: string; q?: string; limit?: number; offset?: number }): Promise<ErrorListResponse>;
  getDwQueries(): Promise<Record<string, string>>;
  executeSql(sql: string, params: unknown[]): Promise<SQLResult>;
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

async function postJson<T>(url: string, body: unknown): Promise<T> {
  const r = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
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
    getProcedures: () => lift(() => api.getProcedures()),
    search: (q) => lift(() => api.search(q)),
    getDW: (n) => lift(() => api.getDW(n)),
    getDwLayout: (n) => lift(() => api.getDwLayout(n)),
    getObjectAst: (n) => lift(() => api.getObjectAst(n)),
    getObjectLayout: (n) => lift(() => api.getObjectLayout(n)),
    getDiagram: (k, p) => lift(() => api.getDiagram(k, p)),
    getQueries: () => lift(() => api.getQueries()),
    runQuery: (n, p) => lift(() => api.runQuery(n, p)),
    runSql: (sql) => lift(() => api.runSql(sql)),
    getExploreTree: () => lift(() => api.getExploreTree()),
    getExploreProcedure: (o, p) => lift(() => api.getExploreProcedure(o, p)),
    getExploreDatawindow: (n) => lift(() => api.getExploreDatawindow(n)),
    getTables: () => lift(() => api.getTables()),
    getTableDetail: (n) => lift(() => api.getTableDetail(n)),
    getErrors: (p) => lift(() => api.getErrors(p)),
    getDwQueries: () => lift(() => api.getDwQueries()),
    executeSql: (sql, params) => lift(() => api.executeSql(sql, params)),
    loadTheme: (): Effect<Theme> => {
      const stored = localStorage.getItem("pb-theme");
      const theme: Theme = stored === "light" || stored === "dark" ? stored : "dark";
      return Effect.send(theme);
    },
    applyTheme: (theme: Theme): Effect<never> => {
      localStorage.setItem("pb-theme", theme);
      document.documentElement.setAttribute("data-theme", theme);
      return Effect.none();
    },
    // Placeholder: pullbackWithNav always overrides this with the real capture implementation.
    navigate: (_action: NavigationAction): Effect<never> => Effect.none(),
    pushUrl: (path: string): void => {
      const current = window.location.pathname + window.location.search;
      if (path !== current) history.pushState({}, "", path);
    },
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

    async getProcedures(): Promise<ProcedureListItem[]> {
      return fetchJson("/api/procedures");
    },

    async search(q: string): Promise<SearchResponse> {
      return fetchJson("/api/search?q=" + encodeURIComponent(q));
    },

    async getDW(name: string): Promise<DwDetailResponse> {
      return fetchJson("/api/datawindow/" + encodeURIComponent(name));
    },

    async getDwLayout(name: string): Promise<DataWindowFile> {
      return fetchJson("/api/objects/" + encodeURIComponent(name) + "/dw");
    },

    async getObjectAst(name: string): Promise<AstData> {
      return fetchJson("/api/objects/" + encodeURIComponent(name) + "/ast");
    },

    async getObjectLayout(name: string): Promise<WindowLayout> {
      return fetchJson("/api/objects/" + encodeURIComponent(name) + "/layout");
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

    async runSql(sql: string): Promise<QueryResult> {
      const r = await fetch("/api/queries/run-sql", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ sql }),
      });
      if (!r.ok) throw new Error(await r.text().then((t) => {
        try { return (JSON.parse(t) as { detail: string }).detail; } catch { return `API ${r.status}`; }
      }));
      return r.json() as Promise<QueryResult>;
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

    async getExploreDatawindow(name: string): Promise<DwDetailResponse> {
      return fetchJson(`/api/datawindow/${encodeURIComponent(name)}`);
    },

    async getTables(): Promise<TableSummary[]> {
      return fetchJson("/api/tables");
    },

    async getTableDetail(name: string): Promise<TableDetail> {
      return fetchJson(`/api/tables/${encodeURIComponent(name)}`);
    },

    async getErrors(params: { kind?: string; q?: string; limit?: number; offset?: number }): Promise<ErrorListResponse> {
      return fetchJson("/api/errors?" + apiParams({ kind: params.kind ?? "", q: params.q ?? "", limit: params.limit ?? 200, offset: params.offset ?? 0 }));
    },

    async getDwQueries(): Promise<Record<string, string>> {
      return fetchJson("/api/runtime/dw-queries");
    },

    async executeSql(sql: string, params: unknown[]): Promise<SQLResult> {
      return postJson("/api/sql/execute", { sql, params });
    },
  };
}
