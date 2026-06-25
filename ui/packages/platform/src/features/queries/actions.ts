// features/queries/actions.ts — Queries feature actions (self-contained).

import type { QueryDef, QueryResult } from "../../types/api.js";

export type QueriesAction =
  | { tag: "load" }
  | { tag: "loaded"; items: QueryDef[] }
  | { tag: "run"; name: string; params: Record<string, string> }
  | { tag: "result"; data: QueryResult }
  | { tag: "error"; error: string }
  | { tag: "restore"; name: string; params: Record<string, string> }
  | { tag: "navigate-to-entity"; entityType: string; entityName: string; objectName: string | null }
  | { tag: "sort"; col: string }
  | { tag: "set-page"; page: number }
  // AskInput free-text actions
  | { tag: "set-ask-text"; text: string }
  | { tag: "submit-ask" }
  | { tag: "toggle-query-pane" }
  | { tag: "set-generated-sql"; sql: string }
  | { tag: "run-sql"; sql: string }
  | { tag: "run-recent"; text: string }
  ;
