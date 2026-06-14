// App state types — the single immutable state tree.

import type { ObjectRow, StatsResponse, QueryDef, QueryResult, SearchResponse, DwExploreDetail } from "./api.js";
import type {
  ObjectDetailResponse,
  ObjectSourceResponse,
  ProcedureDetailResponse,
  DwDetailResponse,
} from "./api.js";
import type { BodyStmt } from "./ast.generated.js";

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

export interface ObjectsState {
  items: ObjectRow[];
  total: number;
  q: string;
  kind: string;
  sort: string;
  order: "asc" | "desc";
  offset: number;
  loading: boolean;
}

export interface DatawindowsState {
  items: ObjectRow[];
  total: number;
  q: string;
  loading: boolean;
}

export interface DiagramsState {
  active: "inheritance" | "calls" | "dw-tables" | "heatmap";
  svg: string | null;
  loading: boolean;
  params: Record<string, string | number>;
  error?: string;
}

export interface QueriesState {
  items: QueryDef[];
  results: QueryResult | { error: string } | null;
  resultsName: string;
  loading: boolean;
}

export interface SearchState {
  term: string;
  results: SearchResponse | null;
  loading: boolean;
}

export interface ExploreState {
  libraries: import("./api.js").ExploreLibrary[];
  expandedNodes: Set<string>;
  selectedNode: string | null;
  astCache: Record<string, BodyStmt[] | { error: string } | null>;
  dwCache: Record<string, DwExploreDetail | { error: string }>;
  loading: boolean;
}

export interface AppState {
  view: ViewName;
  stats: StatsResponse | null;
  objects: ObjectsState;
  objectDetail: ObjectDetailResponse | { error: string } | null;
  sourceDetail: ObjectSourceResponse | { error: string } | null;
  procedureDetail: ProcedureDetailResponse | { error: string } | null;
  allObjects: ObjectRow[];
  datawindows: DatawindowsState;
  dwDetail: DwDetailResponse | { error: string } | null;
  diagrams: DiagramsState;
  queries: QueriesState;
  search: SearchState;
  explore: ExploreState;
}
