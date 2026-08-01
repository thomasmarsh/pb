// features/analysis/actions.ts

import type { LiveProcedureRef, DeadVarFinding, TypeMismatchFinding, CapabilityCatalogItem, CapabilityProcedureRef } from "../../types/api.js";

export type AnalysisAction =
  | { tag: "load-live-procedures" }
  | { tag: "live-procedures-loaded"; items: LiveProcedureRef[] }
  | { tag: "load-dead-vars" }
  | { tag: "dead-vars-loaded"; items: DeadVarFinding[] }
  | { tag: "load-type-mismatches" }
  | { tag: "type-mismatches-loaded"; items: TypeMismatchFinding[] }
  | { tag: "load-capabilities" }
  | { tag: "capabilities-loaded"; items: CapabilityCatalogItem[] }
  | { tag: "load-capability-procedures"; capability: string }
  | { tag: "capability-procedures-loaded"; capability: string; items: CapabilityProcedureRef[] }
  ;
