// app/state.ts — App state: the single state tree shape.

import type { NavState } from "../navigation/types.js";
import type { DashboardState } from "../dashboard/types.js";
import type { ObjectsState } from "../objects/types.js";
import type { DatawindowsState } from "../datawindows/types.js";
import type { DiagramsState } from "../diagrams/types.js";
import type { QueriesState } from "../queries/types.js";
import type { SearchState } from "../search/types.js";
import type { ExploreState } from "../explore/types.js";
import type { TablesState } from "../tables/types.js";
import type { ErrorsState } from "../errors/types.js";
import type { RuntimeState } from "../runtime/reducer.js";

export type { ViewName } from "../navigation/types.js";

export type Theme = "dark" | "light";

export interface InlineDiagramState {
  svg: string | null;
  loading: boolean;
  error: string | null;
}

export interface AppState {
  theme: Theme;
  nav: NavState;
  dashboard: DashboardState;
  objects: ObjectsState;
  datawindows: DatawindowsState;
  tables: TablesState;
  diagrams: DiagramsState;
  queries: QueriesState;
  search: SearchState;
  explore: ExploreState;
  errors: ErrorsState;
  inlineDiagrams: Record<string, InlineDiagramState>;
  runtime: RuntimeState;
}
