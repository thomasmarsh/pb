// features/tables/types.ts

import type { TableSummary, TableDetail } from "../../types/api.js";
import type { Face } from "../../components/FaceToggle.js";
import type { ScrollPair } from "../objects/types.js";

export type { Face };

export interface TablesState {
  items:   TableSummary[];
  total:   number;
  q:       string;
  loading: boolean;
  detail:  TableDetail | null;
  error:   string | null;
  tableFace:      Face;
  tableScrollPos: Record<string, ScrollPair>;
}

export const initialTablesState: TablesState = {
  items: [], total: 0, q: "", loading: false, detail: null, error: null,
  tableFace: "source", tableScrollPos: {},
};
