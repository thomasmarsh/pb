// features/datawindows/types.ts

import type { ObjectRow, DwDetailResponse } from "../../types/api.js";
import type { DataWindowFile } from "../../types/ast.js";

export interface DatawindowsState {
  items: ObjectRow[];
  total: number;
  q: string;
  loading: boolean;
  dwDetail: DwDetailResponse | { error: string } | null;
  dwLayout: DataWindowFile | null;
}
