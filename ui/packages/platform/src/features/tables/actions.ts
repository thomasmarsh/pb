// features/tables/actions.ts

import type { TableSummary, TableDetail, ColumnUsageResponse } from "../../types/api.js";

export type TablesAction =
  | { tag: "search";        q: string }
  | { tag: "filter";        q: string }
  | { tag: "loaded";        items: TableSummary[] }
  | { tag: "select";        name: string }
  | { tag: "detail-loaded"; detail: TableDetail }
  | { tag: "detail-error";  error: string }
  | { tag: "back" }
  // Corpus-wide column usage (Plan 153 D4)
  | { tag: "column-usage-load" }
  | { tag: "column-usage-loaded"; data: ColumnUsageResponse }
  | { tag: "column-usage-error";  error: string }
  ;
