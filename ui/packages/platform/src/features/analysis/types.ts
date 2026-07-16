// features/analysis/types.ts

import type { LiveProcedureRef, DeadVarFinding } from "../../types/api.js";

export interface AnalysisState {
  liveProcedures: LiveProcedureRef[];
  liveProceduresLoaded: boolean;
  deadVars: DeadVarFinding[];
  deadVarsLoaded: boolean;
}
