// features/queries/actions.ts — Queries feature actions (self-contained).

import type { QueryDef, QueryResult } from "../../types/api.js";

export type QueriesAction =
  | { tag: "load" }
  | { tag: "loaded"; items: QueryDef[] }
  | { tag: "run"; name: string; params: Record<string, string> }
  | { tag: "result"; key: string; data: QueryResult }
  | { tag: "error"; key: string; error: string }
  | { tag: "restore"; name: string; params: Record<string, string> }
  | { tag: "navigate-to-entity"; key: string; entityType: string; entityName: string; objectName: string | null }
  | { tag: "sort"; key: string; col: string }
  | { tag: "set-page"; key: string; page: number }
  // AskInput free-text actions
  | { tag: "set-ask-text"; text: string }
  | { tag: "submit-ask" }
  | { tag: "toggle-query-pane" }
  | { tag: "set-generated-sql"; sql: string }
  | { tag: "run-sql"; sql: string }
  | { tag: "run-recent"; text: string }
  ;
