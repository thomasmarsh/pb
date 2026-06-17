// features/objects/actions.ts — Objects feature actions (self-contained).

import type { ListObjectsResponse, ObjectDetailResponse, ObjectSourceResponse, ProcedureDetailResponse, ObjectRow } from "../../types/api.js";

export type ObjectsAction =
  | { type: "back-to-objects" }
  | { type: "search"; q: string }
  | { type: "filter-kind"; kind: string }
  | { type: "sort"; col: string }
  | { type: "page"; offset: number }
  | { type: "loaded"; data: ListObjectsResponse }
  | { type: "select"; name: string }
  | { type: "detail-loaded"; data: ObjectDetailResponse }
  | { type: "detail-error"; error: string }
  | { type: "source-loaded"; data: ObjectSourceResponse }
  | { type: "source-error"; error: string }
  | { type: "all-objects-loaded"; data: ObjectRow[] }
  | { type: "proc-select"; objectName: string; procName: string }
  | { type: "proc-loaded"; data: ProcedureDetailResponse }
  | { type: "proc-error"; error: string }
  | { type: "proc-tab"; tab: string }
  ;
