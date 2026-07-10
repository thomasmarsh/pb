// features/tables/types.ts

import type { SchemaSummary, TableSummary, TableDetail, ColumnUsageResponse, DecompositionCandidatesResponse } from "../../types/api.js";

export interface TablesState {
  // Schemas (SCHEMAS > TABLES > [table] nav) — empty for the common
  // single-schema/no-DDL corpus, which has no navigable schema level at all.
  schemas:        SchemaSummary[];
  schemasLoading: boolean;
  // Schema currently scoping the table list/detail below, if any.
  namespace: string | null;
  // Corpus's configured default schema (from /api/stats), used to seed the
  // schema picker when the route doesn't already specify a namespace.
  defaultNamespace: string | null;
  statsLoading: boolean;
  items:   TableSummary[];
  total:   number;
  q:       string;
  loading: boolean;
  detail:  TableDetail | null;
  error:   string | null;
  // Corpus-wide column usage (Plan 153 D4) — lazily loaded once, reused across every table
  columnUsage: ColumnUsageResponse | { error: string } | null;
  columnUsageLoading: boolean;
  // Decomposition candidates (Plan 153 D5) — per-table, lazily loaded when the panel toggles on.
  // Carries the table-wide Column Affinity overview and per-candidate
  // co-update ritual evidence inline (consolidation, 2026-07-09).
  decompositionCandidates: DecompositionCandidatesResponse | { error: string } | null;
  decompositionCandidatesLoading: boolean;
}

export const initialTablesState: TablesState = {
  schemas: [], schemasLoading: false, namespace: null, defaultNamespace: null, statsLoading: false,
  items: [], total: 0, q: "", loading: false, detail: null, error: null,
  columnUsage: null, columnUsageLoading: false,
  decompositionCandidates: null, decompositionCandidatesLoading: false,
};
