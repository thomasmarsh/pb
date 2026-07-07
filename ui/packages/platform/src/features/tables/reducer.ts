// features/tables/reducer.ts

import { Effect, type Reducer } from "@pb/core";
import type { TablesState } from "./types.js";
import type { TablesAction } from "./actions.js";
import type { TableSummary, TableDetail, ColumnUsageResponse, CoUpdateRitualsResponse, DecompositionCandidatesResponse } from "../../types/api.js";
import type { NavigationAction } from "../navigation/types.js";

export type { TablesState };
export { initialTablesState } from "./types.js";

export interface TablesEnv {
  getTables(): Effect<TableSummary[]>;
  getTableDetail(name: string): Effect<TableDetail>;
  getColumnUsage(): Effect<ColumnUsageResponse>;
  getCoUpdateRituals(): Effect<CoUpdateRitualsResponse>;
  getDecompositionCandidates(table: string): Effect<DecompositionCandidatesResponse>;
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
    draft.decompositionCandidates = null;
    draft.decompositionCandidatesLoading = false;
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
  case "column-usage-load": {
    if (draft.columnUsage || draft.columnUsageLoading) return null;
    draft.columnUsageLoading = true;
    return env.getColumnUsage()
      .map((data): TablesAction => ({ tag: "column-usage-loaded", data }))
      .catch((e): TablesAction => ({ tag: "column-usage-error", error: errMsg(e) }));
  }
  case "column-usage-loaded":
    draft.columnUsage = action.data;
    draft.columnUsageLoading = false;
    return null;
  case "column-usage-error":
    draft.columnUsage = { error: action.error };
    draft.columnUsageLoading = false;
    return null;
  case "co-update-rituals-load": {
    if (draft.coUpdateRituals || draft.coUpdateRitualsLoading) return null;
    draft.coUpdateRitualsLoading = true;
    return env.getCoUpdateRituals()
      .map((data): TablesAction => ({ tag: "co-update-rituals-loaded", data }))
      .catch((e): TablesAction => ({ tag: "co-update-rituals-error", error: errMsg(e) }));
  }
  case "co-update-rituals-loaded":
    draft.coUpdateRituals = action.data;
    draft.coUpdateRitualsLoading = false;
    return null;
  case "co-update-rituals-error":
    draft.coUpdateRituals = { error: action.error };
    draft.coUpdateRitualsLoading = false;
    return null;
  case "decomposition-candidates-load": {
    const already = draft.decompositionCandidates
      && "table" in draft.decompositionCandidates
      && draft.decompositionCandidates.table === action.tableName;
    if (already || draft.decompositionCandidatesLoading) return null;
    draft.decompositionCandidatesLoading = true;
    return env.getDecompositionCandidates(action.tableName)
      .map((data): TablesAction => ({ tag: "decomposition-candidates-loaded", data }))
      .catch((e): TablesAction => ({ tag: "decomposition-candidates-error", error: errMsg(e) }));
  }
  case "decomposition-candidates-loaded":
    draft.decompositionCandidates = action.data;
    draft.decompositionCandidatesLoading = false;
    return null;
  case "decomposition-candidates-error":
    draft.decompositionCandidates = { error: action.error };
    draft.decompositionCandidatesLoading = false;
    return null;
  default:
    return null;
  }
}

export const tablesReducer: Reducer<TablesState, TablesAction, TablesEnv> = reduce;
