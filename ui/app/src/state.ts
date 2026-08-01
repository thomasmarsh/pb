// app/state.ts — App state: the single state tree shape.

import { type JobPollState } from "@pb/core";
import { type NavState, type DashboardState, type ObjectsState, type DatawindowsState, type DiagramsState, type QueriesState, type SearchState, type ExploreState, type TablesState, type DiagnosticsState, type AnalysisState, type DiagramKind, type CfgDiagramResponse, type ExplainPseudocodeResponse } from "@pb/platform";
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

/** One procedure's explain pseudocode fetch, keyed by `${object}::${proc}`.
 * `data` is `null` while the fetch is in flight (no job-poll — `proc_pseudocode`
 * is precomputed corpus-wide, so this is a plain fetch, unlike `CfgDiagramEntry`). */
export interface ExplainEntry {
  object: string;
  proc: string;
  data: ExplainPseudocodeResponse | { error: string } | null;
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
  diagnostics: DiagnosticsState;
  analysis: AnalysisState;
  inlineDiagrams: Record<string, InlineDiagramEntry>;
  cfgDiagrams: Record<string, CfgDiagramEntry>;
  explainPseudocodes: Record<string, ExplainEntry>;
  runtimes: Record<string, RuntimeState>;
  windowManager: WindowManagerState;
  launch: LaunchState;
}
