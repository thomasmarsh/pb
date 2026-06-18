// features/dashboard/reducer.ts

import { Effect } from "../../core/effect.js";
import type { Reducer } from "../../core/reducer.js";
import type { DashboardState } from "./types.js";
import type { DashboardAction } from "./actions.js";
import type { StatsResponse } from "../../types/api.js";

export interface DashboardEnv {
  getStats(): Effect<StatsResponse>;
}

export const initialDashboardState: DashboardState = { stats: null };

function reduce(draft: DashboardState, action: DashboardAction, env: DashboardEnv): Effect<DashboardAction> | null {
  switch (action.tag) {
  case "load":
    return env.getStats().map((stats): DashboardAction => ({ tag: "loaded", stats }));
  case "loaded":
    draft.stats = action.stats;
    return null;
  default:
    return null;
  }
}

export const dashboardReducer: Reducer<DashboardState, DashboardAction, DashboardEnv> = reduce;
