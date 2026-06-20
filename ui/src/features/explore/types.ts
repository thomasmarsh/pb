// features/explore/types.ts — Explore feature state.

import type { ExploreLibrary, DwDetailResponse, ExploreProcDetail, TableSummary, TableDetail, ObjectSourceResponse } from "../../types/api.js";
import type { DataWindowFile } from "../../types/ast.generated.js";

export interface TablesState {
  items: TableSummary[];
  filter: string;
  selected: string | null;
  detail: TableDetail | { error: string } | null;
  loading: boolean;
  detailLoading: boolean;
}

export interface SidebarGroups {
  sourceTree: boolean;
  entityNav: boolean;
  analysisNav: boolean;
}

export interface ExploreState {
  libraries: ExploreLibrary[];
  expandedNodes: Set<string>;
  selectedProc: string | null;
  selectedObject: string | null;
  highlightedProcName: string | null;
  selectedDw: string | null;
  procCache: Record<string, ExploreProcDetail | { error: string }>;
  dwCache: Record<string, DwDetailResponse | { error: string }>;
  dwLayoutCache: Record<string, DataWindowFile>;
  objectSourceCache: Record<string, ObjectSourceResponse | { error: string }>;
  loading: boolean;
  activeTab: "source" | "ast" | "sql" | "diagram";
  treeFilter: string;
  highlightedLine: number | null;
  sidebarGroups: SidebarGroups;
  sidebarCollapsed: boolean;
  tables: TablesState;
  helpOverlayOpen: boolean;
}
