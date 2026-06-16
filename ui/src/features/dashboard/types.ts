// features/dashboard/types.ts

import type { StatsResponse } from "../../types/api.js";

export interface DashboardState {
  stats: StatsResponse | null;
}
