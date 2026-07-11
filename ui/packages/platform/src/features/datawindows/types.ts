// features/datawindows/types.ts

import type { ObjectRow, DwDetailResponse, FootprintResponse } from "../../types/api.js";
import type { DataWindowFile } from "@pb/interpreter";

export interface DatawindowsState {
  items: ObjectRow[];
  total: number;
  q: string;
  loading: boolean;
  dwDetail: DwDetailResponse | { error: string } | null;
  dwLayout: DataWindowFile | null;
  // Unified footprint (Plan 163 Phase 6) — lazily loaded when the panel toggles on
  footprint: FootprintResponse | { error: string } | null;
  footprintLoading: boolean;
}
