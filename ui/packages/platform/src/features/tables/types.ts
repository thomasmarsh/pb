// features/tables/types.ts

import type { TableSummary, TableDetail, ColumnUsageResponse } from "../../types/api.js";

export interface TablesState {
  items:   TableSummary[];
  total:   number;
  q:       string;
  loading: boolean;
  detail:  TableDetail | null;
  error:   string | null;
  // Corpus-wide column usage (Plan 153 D4) — lazily loaded once, reused across every table
  columnUsage: ColumnUsageResponse | { error: string } | null;
  columnUsageLoading: boolean;
}

export const initialTablesState: TablesState = {
  items: [], total: 0, q: "", loading: false, detail: null, error: null,
  columnUsage: null, columnUsageLoading: false,
};
