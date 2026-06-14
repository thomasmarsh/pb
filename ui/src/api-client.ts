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
} from "./types/api.js";
import type { ApiClient } from "./core.js";

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

export function createApiClient(): ApiClient {
  return {
    async getStats(): Promise<StatsResponse> {
      return fetchJson("/api/stats");
    },

    async getObjects(params: Record<string, string | number>): Promise<ListObjectsResponse> {
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

    async getProcedure(obj: string, proc: string): Promise<ProcedureDetailResponse> {
      return fetchJson(`/api/procedures/${encodeURIComponent(obj)}/${encodeURIComponent(proc)}`);
    },

    async search(q: string): Promise<SearchResponse> {
      return fetchJson("/api/search?q=" + encodeURIComponent(q));
    },

    async getDW(name: string): Promise<DwDetailResponse> {
      return fetchJson("/api/dw/" + encodeURIComponent(name));
    },

    async getDiagram(kind: string, params: Record<string, string | number>): Promise<string> {
      const r = await fetch(`/api/diagram/${kind}?` + apiParams(params));
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return r.text();
    },

    async getQueries(): Promise<{ queries: QueryDef[] }> {
      return fetchJson("/api/queries");
    },

    async runQuery(name: string, params: Record<string, string>): Promise<QueryResult> {
      return fetchJson(`/api/queries/${name}/run?` + apiParams(params));
    },

    async getExploreTree(): Promise<ExploreTreeResponse> {
      return fetchJson("/api/explore/tree");
    },

    async getExploreProcedure(objectName: string, procName: string): Promise<{ ast: unknown }> {
      return fetchJson(`/api/explore/procedure/${encodeURIComponent(objectName)}/${encodeURIComponent(procName)}`);
    },

    async getExploreDatawindow(name: string): Promise<DwExploreDetail> {
      return fetchJson(`/api/explore/datawindow/${encodeURIComponent(name)}`);
    },
  };
}
