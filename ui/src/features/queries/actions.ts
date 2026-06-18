// features/queries/actions.ts — Queries feature actions (self-contained).

import type { QueryDef, QueryResult } from "../../types/api.js";

export type QueriesAction =
  | { type: "load" }
  | { type: "loaded"; items: QueryDef[] }
  | { type: "run"; name: string; params: Record<string, string> }
  | { type: "result"; data: QueryResult }
  | { type: "error"; error: string }
  | { type: "restore"; name: string; params: Record<string, string> }
  | { type: "navigate-to-entity"; entityType: string; entityName: string; objectName: string | null }
  | { type: "sort"; col: string }
  | { type: "set-page"; page: number }
  ;
