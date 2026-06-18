// features/search/actions.ts — Search feature actions (self-contained).

import type { SearchResponse } from "../../types/api.js";

export type SearchAction =
  | { type: "term"; term: string }
  | { type: "loaded"; data: SearchResponse }
  | { type: "overlay-open" }
  | { type: "overlay-close" }
  | { type: "overlay-term"; term: string }
  | { type: "overlay-loaded"; data: SearchResponse }
  ;
