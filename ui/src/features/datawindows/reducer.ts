// features/datawindows/reducer.ts

import { Effect } from "../../core/effect.js";
import type { Reducer } from "../../core/reducer.js";
import type { DatawindowsState } from "./types.js";
import type { DatawindowsAction } from "./actions.js";
import type { ListObjectsResponse, DwDetailResponse } from "../../types/api.js";
import type { DataWindowFile } from "../../types/ast.js";
import type { NavigationAction } from "../navigation/types.js";

export interface DatawindowsEnv {
  getObjects(params: Record<string, string | number>): Effect<ListObjectsResponse>;
  getDW(name: string): Effect<DwDetailResponse>;
  getDwLayout(name: string): Effect<DataWindowFile>;
  navigate(action: NavigationAction): Effect<never>;
}

export const initialDatawindowsState: DatawindowsState = {
  items: [], total: 0, q: "", loading: false, dwDetail: null, dwLayout: null,
};

function errMsg(e: unknown): string { return e instanceof Error ? e.message : String(e); }

function reduce(draft: DatawindowsState, action: DatawindowsAction, env: DatawindowsEnv): Effect<DatawindowsAction> | null {
  switch (action.tag) {
  case "back-to-datawindows":
    draft.dwDetail = null;
    return env.navigate({ tag: "navigate", route: { view: "datawindows" } });
  case "search":
    draft.q = action.q;
    draft.loading = true;
    env.navigate({ tag: "navigate", route: { view: "datawindows" } });
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
  default:
    return null;
  }
}

export const datawindowsReducer: Reducer<DatawindowsState, DatawindowsAction, DatawindowsEnv> = reduce;
