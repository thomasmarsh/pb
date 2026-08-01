// features/analysis/types.ts

import type { LiveProcedureRef, DeadVarFinding, TypeMismatchFinding, CapabilityCatalogItem, CapabilityProcedureRef } from "../../types/api.js";

export interface AnalysisState {
  liveProcedures: LiveProcedureRef[];
  liveProceduresLoaded: boolean;
  deadVars: DeadVarFinding[];
  deadVarsLoaded: boolean;
  typeMismatches: TypeMismatchFinding[];
  typeMismatchesLoaded: boolean;
  capabilities: CapabilityCatalogItem[];
  capabilitiesLoaded: boolean;
  capabilityProcedures: Record<string, CapabilityProcedureRef[]>;
}
