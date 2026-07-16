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
  CodeQualityReportResponse,
  QueryDef,
  QueryResult,
  ExploreTreeResponse,

  ExploreProcDetail,
  SchemaSummary,
  TableSummary,
  TableDetail,
  ErrorListResponse,
  LiveProceduresResponse,
  WiringDiagramResponse,
  FootprintResponse,
  ColumnUsageResponse,
  DecompositionCandidatesResponse,
  CfgDiagramResponse,
} from "@pb/platform";
import { type DataWindowFile, type AstData, type WindowLayout } from "@pb/interpreter";
import { Effect, type SQLResult, type JobSubmitResult, type JobPollResult } from "@pb/core";
import type { AppEnv as Env } from "./reducer.js";
import type { Theme } from "./state.js";
import type { NavigationAction } from "@pb/platform";


export interface ApiClient {
  getStats(): Promise<StatsResponse>;
  getCodeQualityReport(): Promise<CodeQualityReportResponse>;
  getObjects(params: Record<string, string | number>): Promise<ListObjectsResponse>;
  getObject(name: string): Promise<ObjectDetailResponse>;
  getObjectSource(name: string): Promise<ObjectSourceResponse>;
  getAllObjects(): Promise<ListObjectsResponse>;
  getProcedure(obj: string, proc: string): Promise<ProcedureDetailResponse>;
  getProcedures(): Promise<ProcedureListItem[]>;
  getWiringDiagram(obj: string, proc: string): Promise<WiringDiagramResponse>;
  getFootprint(object: string, proc?: string): Promise<FootprintResponse>;
  search(q: string): Promise<SearchResponse>;
  getDW(name: string): Promise<DwDetailResponse>;
  getDwLayout(name: string): Promise<DataWindowFile>;
  getObjectAst(name: string): Promise<AstData>;
  getObjectLayout(name: string): Promise<WindowLayout>;
  submitDiagramJob(kind: string, params: Record<string, string | number>): Promise<JobSubmitResult<string>>;
  pollDiagramJob<T>(jobId: string): Promise<JobPollResult<T>>;
  submitCfgDiagramJob(object: string, proc: string): Promise<JobSubmitResult<CfgDiagramResponse>>;
  getQueries(): Promise<{ queries: QueryDef[] }>;
  runQuery(name: string, params: Record<string, string>): Promise<QueryResult>;
  runSql(sql: string): Promise<QueryResult>;
  getExploreTree(): Promise<ExploreTreeResponse>;
  getExploreProcedure(objectName: string, procName: string): Promise<ExploreProcDetail>;
  getExploreDatawindow(name: string): Promise<DwDetailResponse>;
  getSchemas(): Promise<SchemaSummary[]>;
  getTables(namespace?: string): Promise<TableSummary[]>;
  getTableDetail(name: string, namespace?: string): Promise<TableDetail>;
  getColumnUsage(): Promise<ColumnUsageResponse>;
  getDecompositionCandidates(table: string, namespace?: string): Promise<DecompositionCandidatesResponse>;
  getErrors(params: { kind?: string; q?: string; limit?: number; offset?: number }): Promise<ErrorListResponse>;
  getLiveProcedures(): Promise<LiveProceduresResponse>;
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

async function errorDetail(r: Response): Promise<string | undefined> {
  try {
    const body: unknown = await r.json();
    if (body && typeof body === "object") {
      const b = body as Record<string, unknown>;
      if (typeof b.detail === "string") return b.detail;
    }
  } catch {
    // Non-JSON error body — fall through to the generic message.
  }
  return undefined;
}

async function fetchJson<T>(url: string): Promise<T> {
  const r = await fetch(url);
  if (!r.ok) throw new Error((await errorDetail(r)) ?? `API ${r.status}`);
  return r.json() as Promise<T>;
}

async function postJson<T>(url: string, body: unknown): Promise<T> {
  const r = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error((await errorDetail(r)) ?? `API ${r.status}`);
  return r.json() as Promise<T>;
}

export function createEnv(api: ApiClient): Env {
  const lift = <T>(thunk: () => Promise<T>): Effect<T> =>
    Effect.fromPromise(thunk);
  return {
    getStats: () => lift(() => api.getStats()),
    getCodeQualityReport: () => lift(() => api.getCodeQualityReport()),
    getObjects: (p) => lift(() => api.getObjects(p)),
    getObject: (n) => lift(() => api.getObject(n)),
    getObjectSource: (n) => lift(() => api.getObjectSource(n)),
    getAllObjects: () => lift(() => api.getAllObjects()),
    getProcedure: (o, p) => lift(() => api.getProcedure(o, p)),
    getProcedures: () => lift(() => api.getProcedures()),
    getWiringDiagram: (o, p) => lift(() => api.getWiringDiagram(o, p)),
    getFootprint: (o, p) => lift(() => api.getFootprint(o, p)),
    search: (q) => lift(() => api.search(q)),
    getDW: (n) => lift(() => api.getDW(n)),
    getDwLayout: (n) => lift(() => api.getDwLayout(n)),
    getObjectAst: (n) => lift(() => api.getObjectAst(n)),
    getObjectLayout: (n) => lift(() => api.getObjectLayout(n)),
    submitDiagramJob: (k, p) => lift(() => api.submitDiagramJob(k, p)),
    pollDiagramJob: (jobId) => lift(() => api.pollDiagramJob<string>(jobId)),
    submitCfgDiagramJob: (o, p) => lift(() => api.submitCfgDiagramJob(o, p)),
    pollCfgDiagramJob: (jobId) => lift(() => api.pollDiagramJob<CfgDiagramResponse>(jobId)),
    getQueries: () => lift(() => api.getQueries()),
    runQuery: (n, p) => lift(() => api.runQuery(n, p)),
    runSql: (sql) => lift(() => api.runSql(sql)),
    getExploreTree: () => lift(() => api.getExploreTree()),
    getExploreProcedure: (o, p) => lift(() => api.getExploreProcedure(o, p)),
    getExploreDatawindow: (n) => lift(() => api.getExploreDatawindow(n)),
    getSchemas: () => lift(() => api.getSchemas()),
    getTables: (ns?: string) => lift(() => api.getTables(ns)),
    getTableDetail: (n: string, ns?: string) => lift(() => api.getTableDetail(n, ns)),
    getColumnUsage: () => lift(() => api.getColumnUsage()),
    getDecompositionCandidates: (t: string, ns?: string) => lift(() => api.getDecompositionCandidates(t, ns)),
    getErrors: (p) => lift(() => api.getErrors(p)),
    getLiveProcedures: () => lift(() => api.getLiveProcedures().then((r) => r.items)),
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

    async getCodeQualityReport(): Promise<CodeQualityReportResponse> {
      return fetchJson("/api/analysis/report");
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

    async getWiringDiagram(obj: string, proc: string): Promise<WiringDiagramResponse> {
      return fetchJson(
        `/api/diagrams/wiring/${encodeURIComponent(obj)}/${encodeURIComponent(proc)}`,
      );
    },

    async getFootprint(object: string, proc?: string): Promise<FootprintResponse> {
      const qs = proc ? `?proc=${encodeURIComponent(proc)}` : "";
      return fetchJson(`/api/schema/footprint/${encodeURIComponent(object)}${qs}`);
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

    async submitDiagramJob(
      kind: string,
      params: Record<string, string | number>,
    ): Promise<JobSubmitResult<string>> {
      return fetchJson(`/api/diagram/${kind}?` + apiParams({ ...params, async: 1 }));
    },

    async pollDiagramJob<T>(jobId: string): Promise<JobPollResult<T>> {
      return fetchJson(`/api/diagram-jobs/${encodeURIComponent(jobId)}`);
    },

    async submitCfgDiagramJob(object: string, proc: string): Promise<JobSubmitResult<CfgDiagramResponse>> {
      return fetchJson(
        `/api/diagrams/cfg/${encodeURIComponent(object)}/${encodeURIComponent(proc)}?async=1`,
      );
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
      return postJson("/api/queries/run-sql", { sql });
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

    async getSchemas(): Promise<SchemaSummary[]> {
      return fetchJson("/api/schemas");
    },

    async getTables(namespace?: string): Promise<TableSummary[]> {
      const qs = namespace ? "?" + apiParams({ namespace }) : "";
      return fetchJson(`/api/tables${qs}`);
    },

    async getTableDetail(name: string, namespace?: string): Promise<TableDetail> {
      // Namespace is a path segment (table identity), not a query filter:
      // /api/tables/{namespace}/{name} when known, /api/tables/{name} when
      // the caller only has a bare name and needs the server to resolve it.
      return namespace
        ? fetchJson(`/api/tables/${encodeURIComponent(namespace)}/${encodeURIComponent(name)}`)
        : fetchJson(`/api/tables/${encodeURIComponent(name)}`);
    },

    async getColumnUsage(): Promise<ColumnUsageResponse> {
      return fetchJson("/api/schema/column-usage");
    },

    async getDecompositionCandidates(table: string, namespace?: string): Promise<DecompositionCandidatesResponse> {
      const qs = namespace ? "?" + apiParams({ namespace }) : "";
      return fetchJson(`/api/schema/decomposition-candidates/${encodeURIComponent(table)}${qs}`);
    },

    async getErrors(params: { kind?: string; q?: string; limit?: number; offset?: number }): Promise<ErrorListResponse> {
      return fetchJson("/api/errors?" + apiParams({ kind: params.kind ?? "", q: params.q ?? "", limit: params.limit ?? 200, offset: params.offset ?? 0 }));
    },

    async getLiveProcedures(): Promise<LiveProceduresResponse> {
      return fetchJson("/api/analysis/live-procedures");
    },

    async getDwQueries(): Promise<Record<string, string>> {
      return fetchJson("/api/runtime/dw-queries");
    },

    async executeSql(sql: string, params: unknown[]): Promise<SQLResult> {
      return postJson("/api/sql/execute", { sql, params });
    },
  };
}
