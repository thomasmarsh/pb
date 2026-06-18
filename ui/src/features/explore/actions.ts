// features/explore/actions.ts — Explore feature actions (self-contained).

import type { ExploreTreeResponse, DwExploreDetail, ExploreProcDetail, TableSummary, TableDetail } from "../../types/api.js";

export type ExploreAction =
  | { type: "load" }
  | { type: "loaded"; data: ExploreTreeResponse }
  | { type: "toggle"; nodeId: string }
  | { type: "proc-select"; objectName: string; procName: string; nodeId: string }
  | { type: "proc-loaded"; nodeId: string; data: ExploreProcDetail }
  | { type: "proc-error"; nodeId: string; error: string }
  | { type: "expand-all" }
  | { type: "collapse-all" }
  | { type: "dw-select"; dwName: string; nodeId: string }
  | { type: "dw-loaded"; nodeId: string; data: DwExploreDetail }
  | { type: "dw-error"; nodeId: string; error: string }
  | { type: "tab"; tab: "source" | "ast" | "sql" | "diagram" }
  | { type: "filter"; q: string }
  | { type: "highlight-line"; line: number | null }
  | { type: "sidebar-toggle-group"; group: "sourceTree" | "entityNav" | "analysisNav" }
  | { type: "sidebar-set-collapsed"; collapsed: boolean }
  | { type: "sidebar-reveal"; objectName: string; procName?: string }
  | { type: "sidebar-focus-group"; group: "sourceTree" | "entityNav" | "analysisNav" }
  | { type: "help-overlay-toggle" }
  | { type: "tables-load" }
  | { type: "tables-loaded"; items: TableSummary[] }
  | { type: "tables-filter"; q: string }
  | { type: "tables-select"; tableName: string }
  | { type: "tables-detail-loaded"; tableName: string; detail: TableDetail }
  | { type: "tables-detail-error"; tableName: string; error: string }
  ;
