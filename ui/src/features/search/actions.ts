// features/search/actions.ts — Search feature actions (self-contained).

import type { SearchResponse } from "../../types/api.js";
import type { NavigationAction } from "../navigation/types.js";

export type SearchAction =
  | { type: "term"; term: string }
  | { type: "loaded"; data: SearchResponse }
  | { type: "navigate"; action: NavigationAction }
  ;
