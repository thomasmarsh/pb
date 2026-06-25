// features/tables/reducer.ts

import { Effect, type Reducer } from "@pb/core";
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
  switch (action.tag) {
  case "filter":
    draft.q = action.q;
    return null;
  case "search":
    draft.q = action.q;
    draft.loading = true;
    env.navigate({ tag: "navigate", route: { view: "tables" } });
    return env.getTables()
      .map((items): TablesAction => ({ tag: "loaded", items }));
  case "loaded":
    draft.items = action.items;
    draft.total = action.items.length;
    draft.loading = false;
    return null;
  case "select":
    draft.detail = null;
    draft.error = null;
    env.navigate({ tag: "navigate", route: { view: "tableDetail", name: action.name } });
    return env.getTableDetail(action.name)
      .map((detail): TablesAction => ({ tag: "detail-loaded", detail }))
      .catch((e): TablesAction => ({ tag: "detail-error", error: errMsg(e) }));
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
    env.navigate({ tag: "navigate", route: { view: "tables" } });
    return null;
  default:
    return null;
  }
}

export const tablesReducer: Reducer<TablesState, TablesAction, TablesEnv> = reduce;
