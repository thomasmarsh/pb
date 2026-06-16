// features/tables/actions.ts

import type { TableSummary, TableDetail } from "../../types/api.js";

export type TablesAction =
  | { type: "search";        q: string }
  | { type: "loaded";        items: TableSummary[] }
  | { type: "select";        name: string }
  | { type: "detail-loaded"; detail: TableDetail }
  | { type: "detail-error";  error: string }
  | { type: "back" };
