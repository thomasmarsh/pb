// features/objects/actions.ts — Objects feature actions (self-contained).

import type { ListObjectsResponse, ObjectDetailResponse, ObjectSourceResponse, ProcedureDetailResponse, ObjectRow, ProcedureListItem } from "../../types/api.js";

export type ObjectsAction =
  | { tag: "back-to-objects" }
  | { tag: "search"; q: string }
  | { tag: "filter-kind"; kind: string }
  | { tag: "sort"; col: string }
  | { tag: "page"; offset: number }
  | { tag: "loaded"; data: ListObjectsResponse }
  | { tag: "select"; name: string }
  | { tag: "detail-loaded"; data: ObjectDetailResponse }
  | { tag: "detail-error"; error: string }
  | { tag: "source-loaded"; data: ObjectSourceResponse }
  | { tag: "source-error"; error: string }
  | { tag: "all-objects-loaded"; data: ObjectRow[] }
  | { tag: "proc-select"; objectName: string; procName: string }
  | { tag: "proc-loaded"; data: ProcedureDetailResponse }
  | { tag: "proc-error"; error: string }
  | { tag: "proc-tab"; tab: string }
  // Procedures list
  | { tag: "procs-list-load" }
  | { tag: "procs-list-loaded"; data: ProcedureListItem[] }
  | { tag: "procs-list-error"; error: string }
  | { tag: "procs-list-filter"; q: string }
  | { tag: "procs-list-filter-kind"; kind: string }
  | { tag: "procs-list-sort"; col: "name" | "object" | "cyclomatic" | "caller_count" }
  | { tag: "go-slice"; object: string; proc: string; line: number; direction: "backward" | "forward" }
  ;
