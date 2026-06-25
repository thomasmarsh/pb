// features/tables/actions.ts

import type { TableSummary, TableDetail } from "../../types/api.js";

export type TablesAction =
  | { tag: "search";        q: string }
  | { tag: "filter";        q: string }
  | { tag: "loaded";        items: TableSummary[] }
  | { tag: "select";        name: string }
  | { tag: "detail-loaded"; detail: TableDetail }
  | { tag: "detail-error";  error: string }
  | { tag: "back" }
  ;
