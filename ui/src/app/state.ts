// app/state.ts — App state: the single state tree shape.

import type { NavState } from "../features/navigation/types.js";
import type { DashboardState } from "../features/dashboard/types.js";
import type { ObjectsState } from "../features/objects/types.js";
import type { DatawindowsState } from "../features/datawindows/types.js";
import type { DiagramsState } from "../features/diagrams/types.js";
import type { QueriesState } from "../features/queries/types.js";
import type { SearchState } from "../features/search/types.js";
import type { ExploreState } from "../features/explore/types.js";

export type { ViewName } from "../features/navigation/types.js";

export interface AppState {
  nav: NavState;
  dashboard: DashboardState;
  objects: ObjectsState;
  datawindows: DatawindowsState;
  diagrams: DiagramsState;
  queries: QueriesState;
  search: SearchState;
  explore: ExploreState;
}
