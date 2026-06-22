// app/actions.ts — AppAction: tagged sum type routing to each feature reducer.

import type { DashboardAction } from "../dashboard/actions.js";
import type { ExploreAction } from "../explore/actions.js";
import type { ObjectsAction } from "../objects/actions.js";
import type { DatawindowsAction } from "../datawindows/actions.js";
import type { TablesAction } from "../tables/actions.js";
import type { DiagramsAction } from "../diagrams/actions.js";
import type { QueriesAction } from "../queries/actions.js";
import type { SearchAction } from "../search/actions.js";
import type { ErrorsAction } from "../errors/actions.js";
import type { NavigationAction } from "../navigation/types.js";
import type { RuntimeAction } from "../runtime/reducer.js";
import type { WindowManagerAction } from "../window-manager/types.js";
import type { LaunchAction } from "../launch/reducer.js";
import type { DiagramKind } from "../../utils/diagram.js";
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
  | { tag: "runtime"; action: RuntimeAction }
  | { tag: "windowManager"; action: WindowManagerAction }
  | { tag: "launch"; action: LaunchAction };
