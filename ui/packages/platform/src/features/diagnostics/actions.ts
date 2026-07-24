// features/diagnostics/actions.ts — Diagnostics feature actions (self-contained).

import type { ParseErrorRow, TypeCoverageResponse, DiagnosticsTimelineResponse } from "../../types/api.js";
import type { DiagnosticsKindFilter } from "./types.js";

export type DiagnosticsAction =
  | { tag: "load" }
  | { tag: "loaded"; items: ParseErrorRow[]; total: number }
  | { tag: "setFilterKind"; kind: DiagnosticsKindFilter }
  | { tag: "setQuery"; query: string }
  | { tag: "setPage"; page: number }
  | { tag: "select"; row: ParseErrorRow | null }
  | { tag: "error"; error: string }
  | { tag: "typeCoverageLoaded"; data: TypeCoverageResponse }
  | { tag: "typeCoverageError"; error: string }
  | { tag: "timelineLoaded"; data: DiagnosticsTimelineResponse }
  | { tag: "timelineError"; error: string }
  | { tag: "setZoom"; zoom: number }
  ;
