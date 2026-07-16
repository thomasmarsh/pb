// features/analysis/actions.ts

import type { LiveProcedureRef, DeadVarFinding } from "../../types/api.js";

export type AnalysisAction =
  | { tag: "load-live-procedures" }
  | { tag: "live-procedures-loaded"; items: LiveProcedureRef[] }
  | { tag: "load-dead-vars" }
  | { tag: "dead-vars-loaded"; items: DeadVarFinding[] }
  ;
