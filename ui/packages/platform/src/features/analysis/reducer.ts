// features/analysis/reducer.ts

import { Effect, type Reducer } from "@pb/core";
import type { AnalysisState } from "./types.js";
import type { AnalysisAction } from "./actions.js";
import type { LiveProcedureRef, DeadVarFinding, TypeMismatchFinding, CapabilityCatalogItem, CapabilityProcedureRef } from "../../types/api.js";

export interface AnalysisEnv {
  getLiveProcedures(): Effect<LiveProcedureRef[]>;
  getDeadVars(): Effect<DeadVarFinding[]>;
  getTypeMismatches(): Effect<TypeMismatchFinding[]>;
  getCapabilities(): Effect<CapabilityCatalogItem[]>;
  getCapabilityProcedures(capability: string): Effect<CapabilityProcedureRef[]>;
}

export const initialAnalysisState: AnalysisState = {
  liveProcedures: [], liveProceduresLoaded: false,
  deadVars: [], deadVarsLoaded: false,
  typeMismatches: [], typeMismatchesLoaded: false,
  capabilities: [], capabilitiesLoaded: false,
  capabilityProcedures: {},
};

function reduce(draft: AnalysisState, action: AnalysisAction, env: AnalysisEnv): Effect<AnalysisAction> | null {
  switch (action.tag) {
  case "load-live-procedures":
    if (draft.liveProceduresLoaded) return null;
    return env.getLiveProcedures().map((items): AnalysisAction => ({ tag: "live-procedures-loaded", items }));
  case "live-procedures-loaded":
    draft.liveProcedures = action.items;
    draft.liveProceduresLoaded = true;
    return null;
  case "load-dead-vars":
    if (draft.deadVarsLoaded) return null;
    return env.getDeadVars().map((items): AnalysisAction => ({ tag: "dead-vars-loaded", items }));
  case "dead-vars-loaded":
    draft.deadVars = action.items;
    draft.deadVarsLoaded = true;
    return null;
  case "load-type-mismatches":
    if (draft.typeMismatchesLoaded) return null;
    return env.getTypeMismatches().map((items): AnalysisAction => ({ tag: "type-mismatches-loaded", items }));
  case "type-mismatches-loaded":
    draft.typeMismatches = action.items;
    draft.typeMismatchesLoaded = true;
    return null;
  case "load-capabilities":
    if (draft.capabilitiesLoaded) return null;
    return env.getCapabilities().map((items): AnalysisAction => ({ tag: "capabilities-loaded", items }));
  case "capabilities-loaded":
    draft.capabilities = action.items;
    draft.capabilitiesLoaded = true;
    return null;
  case "load-capability-procedures":
    if (draft.capabilityProcedures[action.capability] !== undefined) return null;
    return env.getCapabilityProcedures(action.capability).map((items): AnalysisAction => (
      { tag: "capability-procedures-loaded", capability: action.capability, items }
    ));
  case "capability-procedures-loaded":
    draft.capabilityProcedures[action.capability] = action.items;
    return null;
  default:
    return null;
  }
}

export const analysisReducer: Reducer<AnalysisState, AnalysisAction, AnalysisEnv> = reduce;
