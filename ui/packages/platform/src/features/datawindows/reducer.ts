// features/datawindows/reducer.ts

import { Effect, type Reducer } from "@pb/core";
import type { DatawindowsState } from "./types.js";
import type { DatawindowsAction } from "./actions.js";
import type { ListObjectsResponse, DwDetailResponse, FootprintResponse } from "../../types/api.js";
import type { DataWindowFile } from "@pb/interpreter";
import type { NavigationAction } from "../navigation/types.js";

export interface DatawindowsEnv {
  getObjects(params: Record<string, string | number>): Effect<ListObjectsResponse>;
  getDW(name: string): Effect<DwDetailResponse>;
  getDwLayout(name: string): Effect<DataWindowFile>;
  getFootprint(object: string, proc?: string): Effect<FootprintResponse>;
  navigate(action: NavigationAction): Effect<never>;
}

export const initialDatawindowsState: DatawindowsState = {
  items: [], total: 0, q: "", loading: false, dwDetail: null, dwLayout: null,
  footprint: null, footprintLoading: false,
};

function errMsg(e: unknown): string { return e instanceof Error ? e.message : String(e); }

function reduce(draft: DatawindowsState, action: DatawindowsAction, env: DatawindowsEnv): Effect<DatawindowsAction> | null {
  switch (action.tag) {
  case "back-to-datawindows":
    draft.dwDetail = null;
    return env.navigate({ tag: "navigate", route: { view: "browser", category: "datawindow" } });
  case "search":
    draft.q = action.q;
    draft.loading = true;
    env.navigate({ tag: "navigate", route: { view: "browser", category: "datawindow" } });
    return env.getObjects({ q: action.q, kind: "datawindow", limit: 200 })
      .map((data): DatawindowsAction => ({ tag: "loaded", data }));
  case "loaded":
    draft.items = action.data.items;
    draft.total = action.data.total;
    draft.loading = false;
    return null;
  case "select":
    draft.dwDetail = null;
    draft.dwLayout = null;
    draft.footprint = null;
    draft.footprintLoading = false;
    env.navigate({ tag: "navigate", route: { view: "dwDetail", name: action.name } });
    return Effect.merge(
      env.getDW(action.name)
        .map((data): DatawindowsAction => ({ tag: "detail-loaded", data }))
        .catch((e): DatawindowsAction => ({ tag: "detail-error", error: errMsg(e) })),
      env.getDwLayout(action.name)
        .map((data): DatawindowsAction => ({ tag: "layout-loaded", data }))
        .catch((): DatawindowsAction => ({ tag: "layout-error" })),
    );
  case "detail-loaded":
    draft.dwDetail = { ...action.data, loading: false };
    return null;
  case "layout-loaded":
    draft.dwLayout = action.data;
    return null;
  case "layout-error":
    return null;
  case "detail-error":
    draft.dwDetail = { error: action.error };
    return null;
  case "footprint-load": {
    const already = draft.footprint
      && "object" in draft.footprint
      && draft.footprint.object === action.dwName
      && draft.footprint.kind === "dw_retrieve";
    if (already || draft.footprintLoading) return null;
    draft.footprintLoading = true;
    return env.getFootprint(action.dwName)
      .map((data): DatawindowsAction => ({ tag: "footprint-loaded", data }))
      .catch((e): DatawindowsAction => ({ tag: "footprint-error", error: errMsg(e) }));
  }
  case "footprint-loaded":
    draft.footprint = action.data;
    draft.footprintLoading = false;
    return null;
  case "footprint-error":
    draft.footprint = { error: action.error };
    draft.footprintLoading = false;
    return null;
  default:
    return null;
  }
}

export const datawindowsReducer: Reducer<DatawindowsState, DatawindowsAction, DatawindowsEnv> = reduce;
