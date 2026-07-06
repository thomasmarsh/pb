// features/objects/types.ts

import type { ObjectRow, ObjectDetailResponse, ObjectSourceResponse, ProcedureDetailResponse, ProcedureListItem, WiringDiagramResponse } from "../../types/api.js";
import { type AstData, type WindowLayout } from "@pb/interpreter";

export interface ObjectsState {
  items: ObjectRow[];
  total: number;
  q: string;
  kind: string;
  sort: string;
  order: "asc" | "desc";
  offset: number;
  loading: boolean;
  detail: ObjectDetailResponse | { error: string } | null;
  sourceDetail: ObjectSourceResponse | { error: string } | null;
  astData: AstData | { error: string } | null;
  layout: WindowLayout | null;
  selectedProcName: string | null;
  procedureDetail: ProcedureDetailResponse | { error: string } | null;
  allObjects: ObjectRow[];
  // Wiring diagram (Plan 149 Phase 3) — lazily loaded when the panel toggles on
  wiringDiagram: (WiringDiagramResponse & { object: string; proc: string }) | { error: string } | null;
  wiringDiagramLoading: boolean;
  // Procedures list screen
  proceduresList: ProcedureListItem[] | null;
  proceduresListLoading: boolean;
  proceduresListQ: string;
  proceduresListKind: string;
  proceduresListSort: "name" | "object" | "cyclomatic" | "caller_count";
  proceduresListOrder: "asc" | "desc";
}
