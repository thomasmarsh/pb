// features/tables/actions.ts

import type { TableSummary, TableDetail, ColumnUsageResponse, CoUpdateRitualsResponse, DecompositionCandidatesResponse, ColumnAffinityResponse } from "../../types/api.js";

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
  // Corpus-wide co-update rituals (Plan 153 D1)
  | { tag: "co-update-rituals-load" }
  | { tag: "co-update-rituals-loaded"; data: CoUpdateRitualsResponse }
  | { tag: "co-update-rituals-error";  error: string }
  // Decomposition candidates (Plan 153 D5)
  | { tag: "decomposition-candidates-load"; tableName: string }
  | { tag: "decomposition-candidates-loaded"; data: DecompositionCandidatesResponse }
  | { tag: "decomposition-candidates-error";  error: string }
  // Column affinity (Plan 153 D3)
  | { tag: "column-affinity-load"; tableName: string }
  | { tag: "column-affinity-loaded"; data: ColumnAffinityResponse }
  | { tag: "column-affinity-error";  error: string }
  ;
