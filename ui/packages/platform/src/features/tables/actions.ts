// features/tables/actions.ts

import type { SchemaSummary, TableSummary, TableDetail, ColumnUsageResponse, DecompositionCandidatesResponse } from "../../types/api.js";

export type TablesAction =
  // TableList mount: loads schemas + default namespace + the table list in
  // one dispatch: the reducer owns the sequencing (Plan 157 Phase 4).
  | { tag: "mount"; namespace?: string }
  // Schema picker, inline in TableList (Plan 157 Phase 4)
  | { tag: "schemas-load" }
  | { tag: "schemas-loaded"; schemas: SchemaSummary[] }
  | { tag: "schemas-error";  error: string }
  | { tag: "stats-load" }
  | { tag: "stats-loaded";  defaultNamespace: string | null }
  | { tag: "stats-error" }
  | { tag: "search";        q: string; namespace?: string }
  | { tag: "filter";        q: string }
  | { tag: "loaded";        items: TableSummary[] }
  | { tag: "select";        name: string; namespace?: string }
  | { tag: "detail-loaded"; detail: TableDetail }
  | { tag: "detail-error";  error: string }
  | { tag: "back" }
  // Corpus-wide column usage (Plan 153 D4)
  | { tag: "column-usage-load" }
  | { tag: "column-usage-loaded"; data: ColumnUsageResponse }
  | { tag: "column-usage-error";  error: string }
  // Decomposition candidates (Plan 153 D5) — carries the table-wide Column
  // Affinity overview and per-candidate co-update ritual evidence inline
  // (consolidation, 2026-07-09); those used to be their own standalone
  // panels with their own load actions, now folded into this one fetch.
  | { tag: "decomposition-candidates-load"; tableName: string; namespace?: string }
  | { tag: "decomposition-candidates-loaded"; data: DecompositionCandidatesResponse }
  | { tag: "decomposition-candidates-error";  error: string }
  ;
