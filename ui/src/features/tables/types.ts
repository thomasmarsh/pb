// features/tables/types.ts

import type { TableSummary, TableDetail } from "../../types/api.js";

export interface TablesState {
  items:   TableSummary[];
  total:   number;
  q:       string;
  loading: boolean;
  detail:  TableDetail | null;
  error:   string | null;
}

export const initialTablesState: TablesState = {
  items: [], total: 0, q: "", loading: false, detail: null, error: null,
};
