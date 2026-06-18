// app/actions.ts — AppAction: tagged sum type routing to each feature reducer.

import type { DashboardAction } from "../features/dashboard/actions.js";
import type { ExploreAction } from "../features/explore/actions.js";
import type { ObjectsAction } from "../features/objects/actions.js";
import type { DatawindowsAction } from "../features/datawindows/actions.js";
import type { TablesAction } from "../features/tables/actions.js";
import type { DiagramsAction } from "../features/diagrams/actions.js";
import type { QueriesAction } from "../features/queries/actions.js";
import type { SearchAction } from "../features/search/actions.js";
import type { ErrorsAction } from "../features/errors/actions.js";
import type { NavigationAction } from "../features/navigation/types.js";
import type { Theme } from "./state.js";

export type ThemeAction = { tag: "load" } | { tag: "toggle" } | { tag: "loaded"; theme: Theme };

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
  | { tag: "errors"; action: ErrorsAction };
