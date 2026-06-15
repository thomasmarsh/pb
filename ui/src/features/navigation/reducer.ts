// features/navigation/reducer.ts — Navigation feature reducer.

import { Effect } from "../../core/effect.js";
import type { Reducer } from "../../core/reducer.js";
import type { NavState } from "./types.js";
import type { NavigationAction } from "./types.js";
import type {
  StatsResponse, ListObjectsResponse, ObjectDetailResponse, ObjectSourceResponse,
  ProcedureDetailResponse, DwDetailResponse,
} from "../../types/api.js";

// ── Env ──────────────────────────────────────────────────────────────────────

export interface NavEnv {
  getStats(): Effect<StatsResponse>;
  getObjects(params: Record<string, string | number>): Effect<ListObjectsResponse>;
  getAllObjects(): Effect<ListObjectsResponse>;
  getObject(name: string): Effect<ObjectDetailResponse>;
  getObjectSource(name: string): Effect<ObjectSourceResponse>;
  getProcedure(obj: string, proc: string): Effect<ProcedureDetailResponse>;
  getDW(name: string): Effect<DwDetailResponse>;
}

function errMsg(e: unknown): string { return e instanceof Error ? e.message : String(e); }

// ── Reducer ──────────────────────────────────────────────────────────────────

function reduce(draft: NavState, action: NavigationAction, env: NavEnv): Effect<NavigationAction> | null {
  switch (action.type) {
  case "navigate":
    draft.view = action.view;
    return null;
  case "stats-load":
    return env.getStats().map((stats): NavigationAction => ({ type: "stats-loaded", stats }));
  case "stats-loaded":
    draft.stats = action.stats;
    return null;
  case "object-selected":
    draft.objectDetail = null;
    draft.sourceDetail = null;
    draft.view = "objectDetail";
    return Effect.merge<NavigationAction>(
      env.getObject(action.name)
        .map((data): NavigationAction => ({ type: "object-loaded", data }))
        .catch((e): NavigationAction => ({ type: "object-load-error", error: errMsg(e) })),
      env.getObjectSource(action.name)
        .map((data): NavigationAction => ({ type: "source-loaded", data }))
        .catch((e): NavigationAction => ({ type: "source-error", error: errMsg(e) })),
    );
  case "object-loaded":
    draft.objectDetail = { ...action.data, loading: false };
    return null;
  case "object-load-error":
    draft.objectDetail = { error: action.error };
    return null;
  case "source-loaded":
    draft.sourceDetail = { ...action.data, loading: false };
    return null;
  case "source-error":
    draft.sourceDetail = { error: action.error };
    return null;
  case "all-objects-loaded":
    draft.allObjects = action.data;
    return null;
  case "procedure-selected":
    draft.procedureDetail = null;
    draft.view = "procedureDetail";
    return env.getProcedure(action.objectName, action.procName)
      .map((data): NavigationAction => ({ type: "procedure-loaded", data }))
      .catch((e): NavigationAction => ({ type: "procedure-error", error: errMsg(e) }));
  case "procedure-loaded":
    draft.procedureDetail = { ...action.data, activeTab: "original", loading: false };
    return null;
  case "procedure-error":
    draft.procedureDetail = { error: action.error };
    return null;
  case "procedure-tab":
    if (draft.procedureDetail && "activeTab" in draft.procedureDetail) {
      (draft.procedureDetail as any).activeTab = action.tab;
    }
    return null;
  case "dw-search":
    draft.datawindows.q = action.q;
    draft.datawindows.loading = true;
    return env.getObjects({ q: action.q, kind: "datawindow", limit: 200 })
      .map((data): NavigationAction => ({ type: "dw-loaded", data }));
  case "dw-loaded":
    draft.datawindows.items = action.data.items;
    draft.datawindows.total = action.data.total;
    draft.datawindows.loading = false;
    return null;
  case "dw-selected":
    draft.dwDetail = null;
    draft.view = "dwDetail";
    return env.getDW(action.name)
      .map((data): NavigationAction => ({ type: "dw-detail-loaded", data }))
      .catch((e): NavigationAction => ({ type: "dw-load-error", error: errMsg(e) }));
  case "dw-detail-loaded":
    draft.dwDetail = { ...action.data, loading: false };
    return null;
  case "dw-load-error":
    draft.dwDetail = { error: action.error };
    return null;
  default:
    return null;
  }
}

export const navReducer: Reducer<NavState, NavigationAction, NavEnv> = reduce;
