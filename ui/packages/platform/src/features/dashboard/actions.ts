// features/dashboard/actions.ts

import type { CodeQualityReportResponse, SqlLintSummary, StatsResponse, TableSummary } from "../../types/api.js";

export type DashboardAction =
  | { tag: "load" }
  | { tag: "loaded"; stats: StatsResponse }
  | { tag: "loadTopTables" }
  | { tag: "topTablesLoaded"; tables: TableSummary[] }
  | { tag: "loadReport" }
  | { tag: "reportLoaded"; report: CodeQualityReportResponse }
  | { tag: "loadSqlLint" }
  | { tag: "sqlLintLoaded"; sqlLint: SqlLintSummary }
  ;
