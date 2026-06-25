// features/dashboard/actions.ts

import type { StatsResponse, TableSummary } from "../../types/api.js";

export type DashboardAction =
  | { tag: "load" }
  | { tag: "loaded"; stats: StatsResponse }
  | { tag: "loadTopTables" }
  | { tag: "topTablesLoaded"; tables: TableSummary[] }
  ;
