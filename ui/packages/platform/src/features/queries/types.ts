// features/queries/types.ts

import type { QueryDef, QueryResult } from "../../types/api.js";

// Key identifying which query a run belongs to: a catalogue query's `name`,
// or ASK_RUN_KEY for the free-text Ask/SQL box. Each key's result renders
// inline under that query, not in a single shared results panel.
export const ASK_RUN_KEY = "__ask__";

export interface QueryRunState {
  results: QueryResult | { error: string } | null;
  queryParams: Record<string, string>;
  sql: string | null;   // SQL text executed, for ASK_RUN_KEY runs (drives navigate-to-entity's queryRoute)
  sortCol: string | null;
  sortDir: "asc" | "desc";
  page: number;
  loading: boolean;
}

export interface QueriesState {
  items: QueryDef[];
  itemsLoading: boolean;
  runs: Record<string, QueryRunState>;
  // AskInput free-text state
  askText: string;
  generatedSql: string | null;
  queryPaneOpen: boolean;
  recentQueries: string[];   // most-recent first, max 5
}
