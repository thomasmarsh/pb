// features/datawindows/types.ts

import type { ObjectRow, DwDetailResponse } from "../../types/api.js";
import type { Face } from "../../components/FaceToggle.js";
import type { ScrollPair } from "../objects/types.js";

export type { Face };

export interface DatawindowsState {
  items: ObjectRow[];
  total: number;
  q: string;
  loading: boolean;
  dwDetail: DwDetailResponse | { error: string } | null;
  dwFace: Face;
  dwScrollPos: Record<string, ScrollPair>;
}
