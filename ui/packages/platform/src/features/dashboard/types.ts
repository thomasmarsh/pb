// features/dashboard/types.ts

import type { CodeQualityReportResponse, SqlLintSummary, StatsResponse, TableSummary } from "../../types/api.js";

export interface DashboardState {
  stats: StatsResponse | null;
  topTables: TableSummary[];
  topTablesLoaded: boolean;
  report: CodeQualityReportResponse | null;
  reportLoaded: boolean;
  sqlLint: SqlLintSummary | null;
  sqlLintLoaded: boolean;
}
