// features/queries/actions.ts — Queries feature actions (self-contained).

import type { QueryDef, QueryResult } from "../../types/api.js";
import type { NavigationAction } from "../navigation/types.js";

export type QueriesAction =
  | { type: "load" }
  | { type: "loaded"; items: QueryDef[] }
  | { type: "run"; name: string; params: Record<string, string> }
  | { type: "result"; data: QueryResult }
  | { type: "error"; error: string }
  | { type: "navigate"; action: NavigationAction }
  ;
