// Discriminated union of all app actions.

import type { ViewName, DiagramsState } from "./state.js";
import type {
  StatsResponse,
  ListObjectsResponse,
  ObjectRow,
  ObjectDetailResponse,
  ObjectSourceResponse,
  ProcedureDetailResponse,
  DwDetailResponse,
  QueryDef,
  QueryResult,
  SearchResponse,
  ExploreTreeResponse,
  DwExploreDetail,
  ExploreProcDetail,
  TableSummary,
  TableDetail,
} from "./api.js";

export type AppAction =
  // Navigation
  | { type: "NAVIGATE"; view: ViewName }
  // Stats
  | { type: "STATS_LOAD" }
  | { type: "STATS_LOADED"; stats: StatsResponse }
  // Objects list
  | { type: "OBJECTS_SEARCH"; q: string }
  | { type: "OBJECTS_FILTER_KIND"; kind: string }
  | { type: "OBJECTS_SORT"; col: string }
  | { type: "OBJECTS_PAGE"; offset: number }
  | { type: "OBJECTS_LOADED"; data: ListObjectsResponse }
  // Object detail
  | { type: "OBJECT_SELECTED"; name: string }
  | { type: "OBJECT_LOADED"; data: ObjectDetailResponse }
  | { type: "OBJECT_LOAD_ERROR"; error: string }
  // Source
  | { type: "SOURCE_LOADED"; data: ObjectSourceResponse }
  | { type: "SOURCE_ERROR"; error: string }
  // All objects preload
  | { type: "ALL_OBJECTS_LOADED"; data: ObjectRow[] }
  // Procedure detail
  | { type: "PROCEDURE_SELECTED"; objectName: string; procName: string }
  | { type: "PROCEDURE_LOADED"; data: ProcedureDetailResponse }
  | { type: "PROCEDURE_LOAD_ERROR"; error: string }
  | { type: "PROCEDURE_TAB"; tab: string }
  // DataWindows
  | { type: "DW_SEARCH"; q: string }
  | { type: "DW_LOADED"; data: ListObjectsResponse }
  | { type: "DW_SELECTED"; name: string }
  | { type: "DW_LOADED_DETAIL"; data: DwDetailResponse }
  | { type: "DW_LOAD_ERROR"; error: string }
  // Diagrams
  | { type: "DIAGRAM_SELECT"; kind: DiagramsState["active"] }
  | { type: "DIAGRAM_PARAMS"; params: Record<string, string | number> }
  | { type: "DIAGRAM_GENERATE" }
  | { type: "DIAGRAM_LOADED"; svg: string }
  | { type: "DIAGRAM_ERROR"; error: string }
  // Queries
  | { type: "QUERIES_LOAD" }
  | { type: "QUERIES_LOADED"; items: QueryDef[] }
  | { type: "QUERY_RUN"; name: string; params: Record<string, string> }
  | { type: "QUERY_LOADED"; data: QueryResult }
  | { type: "QUERY_ERROR"; error: string }
  // Search
  | { type: "SEARCH_TERM"; term: string }
  | { type: "SEARCH_LOADED"; data: SearchResponse }
  // Explore
  | { type: "EXPLORE_LOAD" }
  | { type: "EXPLORE_LOADED"; data: ExploreTreeResponse }
  | { type: "EXPLORE_TOGGLE"; nodeId: string }
  | { type: "EXPLORE_PROC_SELECT"; objectName: string; procName: string; nodeId: string }
  | { type: "EXPLORE_PROC_LOADED"; nodeId: string; data: ExploreProcDetail }
  | { type: "EXPLORE_PROC_ERROR"; nodeId: string; error: string }
  | { type: "EXPLORE_EXPAND_ALL" }
  | { type: "EXPLORE_COLLAPSE_ALL" }
  | { type: "EXPLORE_DW_SELECT"; dwName: string; nodeId: string }
  | { type: "EXPLORE_DW_LOADED"; nodeId: string; data: DwExploreDetail }
  | { type: "EXPLORE_DW_ERROR"; nodeId: string; error: string }
  | { type: "EXPLORE_TAB"; tab: "source" | "ast" }
  | { type: "EXPLORE_FILTER"; q: string }
  | { type: "EXPLORE_HIGHLIGHT_LINE"; line: number | null }
  // Tables browser
  | { type: "EXPLORE_LEFT_TAB"; tab: "objects" | "tables" }
  | { type: "TABLES_LOAD" }
  | { type: "TABLES_LOADED"; items: TableSummary[] }
  | { type: "TABLES_FILTER"; q: string }
  | { type: "TABLE_SELECT"; tableName: string }
  | { type: "TABLE_DETAIL_LOADED"; tableName: string; detail: TableDetail }
  | { type: "TABLE_DETAIL_ERROR"; tableName: string; error: string };
