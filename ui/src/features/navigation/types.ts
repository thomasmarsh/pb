// features/navigation/types.ts — Navigation types and actions.

import type {
  StatsResponse, ListObjectsResponse, ObjectDetailResponse, ObjectSourceResponse,
  ProcedureDetailResponse, DwDetailResponse, ObjectRow,
} from "../../types/api.js";

export interface NavState {
  view: ViewName;
  stats: StatsResponse | null;
  objectDetail: ObjectDetailResponse | { error: string } | null;
  sourceDetail: ObjectSourceResponse | { error: string } | null;
  procedureDetail: ProcedureDetailResponse | { error: string } | null;
  allObjects: ObjectRow[];
  datawindows: DatawindowsState;
  dwDetail: DwDetailResponse | { error: string } | null;
}

export type ViewName =
  | "dashboard"
  | "objects"
  | "objectDetail"
  | "procedureDetail"
  | "datawindows"
  | "dwDetail"
  | "diagrams"
  | "queries"
  | "search"
  | "explore";

export interface DatawindowsState {
  items: ObjectRow[];
  total: number;
  q: string;
  loading: boolean;
}

export type NavigationAction =
  | { type: "navigate"; view: ViewName }
  | { type: "stats-load" }
  | { type: "stats-loaded"; stats: StatsResponse }
  | { type: "object-selected"; name: string }
  | { type: "object-loaded"; data: ObjectDetailResponse }
  | { type: "object-load-error"; error: string }
  | { type: "source-loaded"; data: ObjectSourceResponse }
  | { type: "source-error"; error: string }
  | { type: "all-objects-loaded"; data: ObjectRow[] }
  | { type: "procedure-selected"; objectName: string; procName: string }
  | { type: "procedure-loaded"; data: ProcedureDetailResponse }
  | { type: "procedure-error"; error: string }
  | { type: "procedure-tab"; tab: string }
  | { type: "dw-search"; q: string }
  | { type: "dw-loaded"; data: ListObjectsResponse }
  | { type: "dw-selected"; name: string }
  | { type: "dw-detail-loaded"; data: DwDetailResponse }
  | { type: "dw-load-error"; error: string };
