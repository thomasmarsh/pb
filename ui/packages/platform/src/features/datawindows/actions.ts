// features/datawindows/actions.ts

import type { ListObjectsResponse, DwDetailResponse, FootprintResponse } from "../../types/api.js";
import type { DataWindowFile } from "@pb/interpreter";

export type DatawindowsAction =
  | { tag: "back-to-datawindows" }
  | { tag: "search"; q: string }
  | { tag: "loaded"; data: ListObjectsResponse }
  | { tag: "select"; name: string }
  | { tag: "detail-loaded"; data: DwDetailResponse }
  | { tag: "detail-error"; error: string }
  | { tag: "layout-loaded"; data: DataWindowFile }
  | { tag: "layout-error" }
  // Unified footprint (Plan 163 Phase 6)
  | { tag: "footprint-load"; dwName: string }
  | { tag: "footprint-loaded"; data: FootprintResponse }
  | { tag: "footprint-error"; error: string }
  ;
