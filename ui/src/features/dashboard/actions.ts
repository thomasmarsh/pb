// features/dashboard/actions.ts

import type { StatsResponse } from "../../types/api.js";

export type DashboardAction =
  | { tag: "load" }
  | { tag: "loaded"; stats: StatsResponse }
  ;
