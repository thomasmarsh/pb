// app/state.ts — App state: the single state tree shape.

import { type NavState, type DashboardState, type ObjectsState, type DatawindowsState, type DiagramsState, type QueriesState, type SearchState, type ExploreState, type TablesState, type ErrorsState } from "@pb/platform";
import { type RuntimeState, type WindowManagerState, type LaunchState } from "@pb/windowing";

export type { ViewName } from "@pb/platform";

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
  runtimes: Record<string, RuntimeState>;
  windowManager: WindowManagerState;
  launch: LaunchState;
}
