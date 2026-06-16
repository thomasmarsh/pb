// features/dashboard/actions.ts

import type { StatsResponse } from "../../types/api.js";

export type DashboardAction =
  | { type: "load" }
  | { type: "loaded"; stats: StatsResponse }
  ;
