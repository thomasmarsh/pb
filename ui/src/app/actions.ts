// app/actions.ts — AppAction: tagged sum type routing to each feature reducer.

import type { DashboardAction } from "../features/dashboard/actions.js";
import type { ExploreAction } from "../features/explore/actions.js";
import type { ObjectsAction } from "../features/objects/actions.js";
import type { DatawindowsAction } from "../features/datawindows/actions.js";
import type { DiagramsAction } from "../features/diagrams/actions.js";
import type { QueriesAction } from "../features/queries/actions.js";
import type { SearchAction } from "../features/search/actions.js";
import type { NavigationAction } from "../features/navigation/types.js";

export type AppAction =
  | { tag: "nav"; action: NavigationAction }
  | { tag: "dashboard"; action: DashboardAction }
  | { tag: "explore"; action: ExploreAction }
  | { tag: "objects"; action: ObjectsAction }
  | { tag: "datawindows"; action: DatawindowsAction }
  | { tag: "diagrams"; action: DiagramsAction }
  | { tag: "queries"; action: QueriesAction }
  | { tag: "search"; action: SearchAction };
