// features/search/actions.ts — Search feature actions (self-contained).

import type { SearchResponse } from "../../types/api.js";

export type SearchAction =
  | { type: "term"; term: string }
  | { type: "loaded"; data: SearchResponse }
  ;
