// app/actions.ts — AppAction: tagged sum type routing to each feature reducer.

import type { DashboardAction } from "@pb/platform";
import { type ExploreAction, type ObjectsAction, type DatawindowsAction, type TablesAction, type DiagramsAction, type QueriesAction, type SearchAction, type ErrorsAction, type NavigationAction, type DiagramKind } from "@pb/platform";
import { type RuntimeAction, type WindowManagerAction, type LaunchAction } from "@pb/windowing";
import type { Theme } from "./state.js";

export type ThemeAction = { tag: "load" } | { tag: "toggle" } | { tag: "loaded"; theme: Theme };

export type InlineDiagramAction =
  | { tag: "request"; key: string; kind: DiagramKind; params: Record<string, string | number> }
  | { tag: "loaded"; key: string; svg: string }
  | { tag: "error"; key: string; error: string };

export type AppAction =
  | { tag: "theme"; action: ThemeAction }
  | { tag: "nav"; action: NavigationAction }
  | { tag: "dashboard"; action: DashboardAction }
  | { tag: "explore"; action: ExploreAction }
  | { tag: "objects"; action: ObjectsAction }
  | { tag: "datawindows"; action: DatawindowsAction }
  | { tag: "tables";      action: TablesAction }
  | { tag: "diagrams";    action: DiagramsAction }
  | { tag: "queries"; action: QueriesAction }
  | { tag: "search"; action: SearchAction }
  | { tag: "errors"; action: ErrorsAction }
  | { tag: "inlineDiagram"; action: InlineDiagramAction }
  | { tag: "runtime"; windowId: string; action: RuntimeAction }
  | { tag: "windowManager"; action: WindowManagerAction }
  | { tag: "launch"; action: LaunchAction };
