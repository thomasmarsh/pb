// features/dashboard/reducer.ts

import { Effect, type Reducer } from "@pb/core";
import type { DashboardState } from "./types.js";
import type { DashboardAction } from "./actions.js";
import type { StatsResponse, TableSummary } from "../../types/api.js";

export interface DashboardEnv {
  getStats(): Effect<StatsResponse>;
  getTables(): Effect<TableSummary[]>;
}

export const initialDashboardState: DashboardState = { stats: null, topTables: [], topTablesLoaded: false };

function reduce(draft: DashboardState, action: DashboardAction, env: DashboardEnv): Effect<DashboardAction> | null {
  switch (action.tag) {
  case "load":
    return env.getStats().map((stats): DashboardAction => ({ tag: "loaded", stats }));
  case "loaded":
    draft.stats = action.stats;
    return null;
  case "loadTopTables":
    if (draft.topTablesLoaded) return null;
    return env.getTables().map((tables): DashboardAction => ({ tag: "topTablesLoaded", tables }));
  case "topTablesLoaded":
    draft.topTables = action.tables;
    draft.topTablesLoaded = true;
    return null;
  default:
    return null;
  }
}

export const dashboardReducer: Reducer<DashboardState, DashboardAction, DashboardEnv> = reduce;
