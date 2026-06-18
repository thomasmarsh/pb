// features/explore/actions.ts — Explore feature actions (self-contained).

import type { ExploreTreeResponse, DwExploreDetail, ExploreProcDetail, TableSummary, TableDetail } from "../../types/api.js";

export type ExploreAction =
  | { tag: "load" }
  | { tag: "loaded"; data: ExploreTreeResponse }
  | { tag: "toggle"; nodeId: string }
  | { tag: "proc-select"; objectName: string; procName: string; nodeId: string }
  | { tag: "proc-loaded"; nodeId: string; data: ExploreProcDetail }
  | { tag: "proc-error"; nodeId: string; error: string }
  | { tag: "expand-all" }
  | { tag: "collapse-all" }
  | { tag: "dw-select"; dwName: string; nodeId: string }
  | { tag: "dw-loaded"; nodeId: string; data: DwExploreDetail }
  | { tag: "dw-error"; nodeId: string; error: string }
  | { tag: "tab"; tab: "source" | "ast" | "sql" | "diagram" }
  | { tag: "filter"; q: string }
  | { tag: "highlight-line"; line: number | null }
  | { tag: "sidebar-toggle-group"; group: "sourceTree" | "entityNav" | "analysisNav" }
  | { tag: "sidebar-set-collapsed"; collapsed: boolean }
  | { tag: "sidebar-reveal"; objectName: string; procName?: string }
  | { tag: "sidebar-focus-group"; group: "sourceTree" | "entityNav" | "analysisNav" }
  | { tag: "help-overlay-toggle" }
  | { tag: "tables-load" }
  | { tag: "tables-loaded"; items: TableSummary[] }
  | { tag: "tables-filter"; q: string }
  | { tag: "tables-select"; tableName: string }
  | { tag: "tables-detail-loaded"; tableName: string; detail: TableDetail }
  | { tag: "tables-detail-error"; tableName: string; error: string }
  ;
