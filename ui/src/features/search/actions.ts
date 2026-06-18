// features/search/actions.ts — Search feature actions (self-contained).

import type { SearchResponse } from "../../types/api.js";

export type SearchAction =
  | { tag: "term"; term: string }
  | { tag: "loaded"; data: SearchResponse }
  | { tag: "overlay-open" }
  | { tag: "overlay-close" }
  | { tag: "overlay-term"; term: string }
  | { tag: "overlay-loaded"; data: SearchResponse }
  ;
