// features/search/types.ts

import type { SearchResponse } from "../../types/api.js";

export interface SearchState {
  term: string;
  results: SearchResponse | null;
  loading: boolean;
}
