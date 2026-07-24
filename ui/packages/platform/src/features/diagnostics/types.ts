// features/diagnostics/types.ts

import type { ParseErrorRow, TypeCoverageResponse, DiagnosticsTimelineResponse } from "../../types/api.js";

export type DiagnosticsKindFilter = "all" | "powerscript" | "sql";

export const PAGE_SIZE = 100;

export interface DiagnosticsState {
  items: ParseErrorRow[];
  total: number;
  loading: boolean;
  filterKind: DiagnosticsKindFilter;
  query: string;
  page: number;
  selected: ParseErrorRow | null;
  typeCoverage: TypeCoverageResponse | null;
  timeline: DiagnosticsTimelineResponse | null;
  zoom: number;
  timelineSvg: string;
}
