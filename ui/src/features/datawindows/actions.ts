// features/datawindows/actions.ts

import type { ListObjectsResponse, DwDetailResponse } from "../../types/api.js";

export type DatawindowsAction =
  | { type: "back-to-datawindows" }
  | { type: "search"; q: string }
  | { type: "loaded"; data: ListObjectsResponse }
  | { type: "select"; name: string }
  | { type: "detail-loaded"; data: DwDetailResponse }
  | { type: "detail-error"; error: string }
  | { type: "set-dw-face"; name: string; face: import("./types.js").Face; scrollTop: number }
  ;
