// features/analysis/actions.ts

import type { LiveProcedureRef, DeadVarFinding, TypeMismatchFinding } from "../../types/api.js";

export type AnalysisAction =
  | { tag: "load-live-procedures" }
  | { tag: "live-procedures-loaded"; items: LiveProcedureRef[] }
  | { tag: "load-dead-vars" }
  | { tag: "dead-vars-loaded"; items: DeadVarFinding[] }
  | { tag: "load-type-mismatches" }
  | { tag: "type-mismatches-loaded"; items: TypeMismatchFinding[] }
  ;
