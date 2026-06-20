// features/datawindows/actions.ts

import type { ListObjectsResponse, DwDetailResponse } from "../../types/api.js";
import type { DataWindowFile } from "../../types/ast.generated.js";

export type DatawindowsAction =
  | { tag: "back-to-datawindows" }
  | { tag: "search"; q: string }
  | { tag: "loaded"; data: ListObjectsResponse }
  | { tag: "select"; name: string }
  | { tag: "detail-loaded"; data: DwDetailResponse }
  | { tag: "detail-error"; error: string }
  | { tag: "layout-loaded"; data: DataWindowFile }
  | { tag: "layout-error" }
  ;
