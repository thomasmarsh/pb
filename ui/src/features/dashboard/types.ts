// features/dashboard/types.ts

import type { StatsResponse, TableSummary } from "../../types/api.js";

export interface DashboardState {
  stats: StatsResponse | null;
  topTables: TableSummary[];
  topTablesLoaded: boolean;
}
