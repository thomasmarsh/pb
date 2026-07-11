// features/analysis/actions.ts

import type { LiveProcedureRef } from "../../types/api.js";

export type AnalysisAction =
  | { tag: "load-live-procedures" }
  | { tag: "live-procedures-loaded"; items: LiveProcedureRef[] }
  ;
