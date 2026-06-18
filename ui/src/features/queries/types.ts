// features/queries/types.ts

import type { QueryDef, QueryResult } from "../../types/api.js";

export interface QueriesState {
  items: QueryDef[];
  results: QueryResult | { error: string } | null;
  resultsName: string;
  queryParams: Record<string, string>;
  sortCol: string | null;
  sortDir: "asc" | "desc";
  page: number;
  loading: boolean;
  // AskInput free-text state
  askText: string;
  generatedSql: string | null;
  queryPaneOpen: boolean;
  recentQueries: string[];   // most-recent first, max 5
  isSqlMode: boolean;        // last query was direct SQL (not a named query)
}
