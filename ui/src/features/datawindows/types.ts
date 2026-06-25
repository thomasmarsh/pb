// features/datawindows/types.ts

import type { ObjectRow, DwDetailResponse } from "../../types/api.js";
import type { DataWindowFile } from "@pb/interpreter";

export interface DatawindowsState {
  items: ObjectRow[];
  total: number;
  q: string;
  loading: boolean;
  dwDetail: DwDetailResponse | { error: string } | null;
  dwLayout: DataWindowFile | null;
}
