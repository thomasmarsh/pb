// features/datawindows/actions.ts

import type { ListObjectsResponse, DwDetailResponse } from "../../types/api.js";

export type DatawindowsAction =
  | { type: "search"; q: string }
  | { type: "loaded"; data: ListObjectsResponse }
  | { type: "select"; name: string }
  | { type: "detail-loaded"; data: DwDetailResponse }
  | { type: "detail-error"; error: string }
  ;
