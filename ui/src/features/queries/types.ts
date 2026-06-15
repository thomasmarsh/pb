// features/queries/types.ts

import type { QueryDef, QueryResult } from "../../types/api.js";

export interface QueriesState {
  items: QueryDef[];
  results: QueryResult | { error: string } | null;
  resultsName: string;
  loading: boolean;
}
