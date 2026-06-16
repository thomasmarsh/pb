// features/datawindows/reducer.ts

import { Effect } from "../../core/effect.js";
import type { Reducer } from "../../core/reducer.js";
import type { DatawindowsState } from "./types.js";
import type { DatawindowsAction } from "./actions.js";
import type { ListObjectsResponse, DwDetailResponse } from "../../types/api.js";
import type { NavigationAction } from "../navigation/types.js";

export interface DatawindowsEnv {
  getObjects(params: Record<string, string | number>): Effect<ListObjectsResponse>;
  getDW(name: string): Effect<DwDetailResponse>;
  navigate(action: NavigationAction): Effect<never>;
}

export const initialDatawindowsState: DatawindowsState = {
  items: [], total: 0, q: "", loading: false, dwDetail: null,
};

function errMsg(e: unknown): string { return e instanceof Error ? e.message : String(e); }

function reduce(draft: DatawindowsState, action: DatawindowsAction, env: DatawindowsEnv): Effect<DatawindowsAction> | null {
  switch (action.type) {
  case "search":
    draft.q = action.q;
    draft.loading = true;
    env.navigate({ type: "navigate", route: { view: "datawindows" } });
    return env.getObjects({ q: action.q, kind: "datawindow", limit: 200 })
      .map((data): DatawindowsAction => ({ type: "loaded", data }));
  case "loaded":
    draft.items = action.data.items;
    draft.total = action.data.total;
    draft.loading = false;
    return null;
  case "select":
    draft.dwDetail = null;
    env.navigate({ type: "navigate", route: { view: "dwDetail", name: action.name } });
    return env.getDW(action.name)
      .map((data): DatawindowsAction => ({ type: "detail-loaded", data }))
      .catch((e): DatawindowsAction => ({ type: "detail-error", error: errMsg(e) }));
  case "detail-loaded":
    draft.dwDetail = { ...action.data, loading: false };
    return null;
  case "detail-error":
    draft.dwDetail = { error: action.error };
    return null;
  default:
    return null;
  }
}

export const datawindowsReducer: Reducer<DatawindowsState, DatawindowsAction, DatawindowsEnv> = reduce;
