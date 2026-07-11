// features/analysis/reducer.ts

import { Effect, type Reducer } from "@pb/core";
import type { AnalysisState } from "./types.js";
import type { AnalysisAction } from "./actions.js";
import type { LiveProcedureRef } from "../../types/api.js";

export interface AnalysisEnv {
  getLiveProcedures(): Effect<LiveProcedureRef[]>;
}

export const initialAnalysisState: AnalysisState = { liveProcedures: [], liveProceduresLoaded: false };

function reduce(draft: AnalysisState, action: AnalysisAction, env: AnalysisEnv): Effect<AnalysisAction> | null {
  switch (action.tag) {
  case "load-live-procedures":
    if (draft.liveProceduresLoaded) return null;
    return env.getLiveProcedures().map((items): AnalysisAction => ({ tag: "live-procedures-loaded", items }));
  case "live-procedures-loaded":
    draft.liveProcedures = action.items;
    draft.liveProceduresLoaded = true;
    return null;
  default:
    return null;
  }
}

export const analysisReducer: Reducer<AnalysisState, AnalysisAction, AnalysisEnv> = reduce;
