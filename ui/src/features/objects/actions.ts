// features/objects/actions.ts — Objects feature actions (self-contained).

import type { ListObjectsResponse } from "../../types/api.js";
import type { NavigationAction } from "../navigation/types.js";

export type ObjectsAction =
  | { type: "search"; q: string }
  | { type: "filter-kind"; kind: string }
  | { type: "sort"; col: string }
  | { type: "page"; offset: number }
  | { type: "loaded"; data: ListObjectsResponse }
  | { type: "navigate"; action: NavigationAction }
  ;
