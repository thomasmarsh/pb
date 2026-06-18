// features/tables/reducer.ts

import { Effect } from "../../core/effect.js";
import type { Reducer } from "../../core/reducer.js";
import type { TablesState } from "./types.js";
import type { TablesAction } from "./actions.js";
import type { TableSummary, TableDetail } from "../../types/api.js";
import type { NavigationAction } from "../navigation/types.js";

export type { TablesState };
export { initialTablesState } from "./types.js";

export interface TablesEnv {
  getTables(): Effect<TableSummary[]>;
  getTableDetail(name: string): Effect<TableDetail>;
  navigate(action: NavigationAction): Effect<never>;
}

function errMsg(e: unknown): string { return e instanceof Error ? e.message : String(e); }

function reduce(draft: TablesState, action: TablesAction, env: TablesEnv): Effect<TablesAction> | null {
  switch (action.type) {
  case "filter":
    draft.q = action.q;
    return null;
  case "search":
    draft.q = action.q;
    draft.loading = true;
    env.navigate({ type: "navigate", route: { view: "tables" } });
    return env.getTables()
      .map((items): TablesAction => ({ type: "loaded", items }));
  case "loaded":
    draft.items = action.items;
    draft.total = action.items.length;
    draft.loading = false;
    return null;
  case "select":
    draft.detail = null;
    draft.error = null;
    env.navigate({ type: "navigate", route: { view: "tableDetail", name: action.name } });
    return env.getTableDetail(action.name)
      .map((detail): TablesAction => ({ type: "detail-loaded", detail }))
      .catch((e): TablesAction => ({ type: "detail-error", error: errMsg(e) }));
  case "detail-loaded":
    draft.detail = action.detail;
    draft.loading = false;
    return null;
  case "detail-error":
    draft.error = action.error;
    draft.loading = false;
    return null;
  case "back":
    draft.detail = null;
    draft.error = null;
    env.navigate({ type: "navigate", route: { view: "tables" } });
    return null;
  case "set-table-face": {
    const prev = draft.tableScrollPos[action.name] ?? { source: 0, analysis: 0 };
    draft.tableScrollPos[action.name] = {
      ...prev,
      [draft.tableFace]: action.scrollTop,
    };
    draft.tableFace = action.face;
    return null;
  }
  default:
    return null;
  }
}

export const tablesReducer: Reducer<TablesState, TablesAction, TablesEnv> = reduce;
