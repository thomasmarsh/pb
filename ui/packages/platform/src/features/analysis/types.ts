// features/analysis/types.ts

import type { LiveProcedureRef } from "../../types/api.js";

export interface AnalysisState {
  liveProcedures: LiveProcedureRef[];
  liveProceduresLoaded: boolean;
}
