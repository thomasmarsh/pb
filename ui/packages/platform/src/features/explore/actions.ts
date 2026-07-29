// features/explore/actions.ts — Explore feature actions (self-contained).

import type { ExploreTreeResponse, DwDetailResponse, ExploreProcDetail, ObjectSourceResponse, ListObjectsResponse } from "../../types/api.js";
import type { DataWindowFile } from "@pb/interpreter";

export type ExploreAction =
  | { tag: "load" }
  | { tag: "loaded"; data: ExploreTreeResponse }
  | { tag: "toggle"; nodeId: string }
  | { tag: "obj-select"; objectName: string; nodeId: string }
  | { tag: "obj-loaded"; objectName: string; data: ObjectSourceResponse }
  | { tag: "obj-error"; objectName: string; error: string }
  | { tag: "proc-select"; objectName: string; procName: string; nodeId: string }
  | { tag: "proc-loaded"; nodeId: string; data: ExploreProcDetail }
  | { tag: "proc-error"; nodeId: string; error: string }
  | { tag: "expand-all" }
  | { tag: "collapse-all" }
  | { tag: "dw-select"; dwName: string; nodeId: string }
  | { tag: "dw-loaded"; nodeId: string; data: DwDetailResponse }
  | { tag: "dw-error"; nodeId: string; error: string }
  | { tag: "dw-layout-loaded"; nodeId: string; data: DataWindowFile }
  | { tag: "dw-layout-error"; nodeId: string }
  | { tag: "tab"; tab: "source" | "ast" | "sql" | "diagram" }
  | { tag: "filter"; q: string }
  | { tag: "highlight-line"; line: number | null }
  | { tag: "sidebar-toggle-group"; group: "sourceTree" | "analysisNav" }
  | { tag: "sidebar-set-collapsed"; collapsed: boolean }
  | { tag: "sidebar-reveal"; objectName: string; procName?: string }
  | { tag: "sidebar-focus-group"; group: "sourceTree" | "analysisNav" }
  | { tag: "help-overlay-toggle" }
  | { tag: "browser-tab"; category: string }
  | { tag: "browser-loaded"; data: ListObjectsResponse }
  | { tag: "browser-filter"; q: string }
  ;
