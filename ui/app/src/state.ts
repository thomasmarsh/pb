// app/state.ts — App state: the single state tree shape.

import { type JobPollState } from "@pb/core";
import { type NavState, type DashboardState, type ObjectsState, type DatawindowsState, type DiagramsState, type QueriesState, type SearchState, type ExploreState, type TablesState, type ErrorsState, type AnalysisState, type DiagramKind, type CfgDiagramResponse } from "@pb/platform";
import { type RuntimeState, type WindowManagerState, type LaunchState } from "@pb/windowing";

export type { ViewName } from "@pb/platform";

export type Theme = "dark" | "light";

/** One inline diagram's submit/poll job, plus the kind+params needed to
 * resubmit if this entry's "start" is ever re-dispatched (e.g. a retry). */
export interface InlineDiagramEntry {
  kind: DiagramKind;
  params: Record<string, string | number>;
  job: JobPollState<string>;
}

/** Same shape for the CFG diagram job, keyed by `${object}::${proc}`. */
export interface CfgDiagramEntry {
  object: string;
  proc: string;
  job: JobPollState<CfgDiagramResponse>;
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
  analysis: AnalysisState;
  inlineDiagrams: Record<string, InlineDiagramEntry>;
  cfgDiagrams: Record<string, CfgDiagramEntry>;
  runtimes: Record<string, RuntimeState>;
  windowManager: WindowManagerState;
  launch: LaunchState;
}
