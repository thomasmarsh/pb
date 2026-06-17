// features/explore/types.ts — Explore feature state.

import type { ExploreLibrary, DwExploreDetail, ExploreProcDetail, TableSummary, TableDetail } from "../../types/api.js";

export interface TablesState {
  items: TableSummary[];
  filter: string;
  selected: string | null;
  detail: TableDetail | { error: string } | null;
  loading: boolean;
  detailLoading: boolean;
}

export interface ExploreState {
  libraries: ExploreLibrary[];
  expandedNodes: Set<string>;
  selectedProc: string | null;
  selectedDw: string | null;
  procCache: Record<string, ExploreProcDetail | { error: string }>;
  dwCache: Record<string, DwExploreDetail | { error: string }>;
  loading: boolean;
  activeTab: "source" | "ast" | "sql" | "diagram";
  treeFilter: string;
  highlightedLine: number | null;
  leftTab: "objects" | "tables";
  tables: TablesState;
}
