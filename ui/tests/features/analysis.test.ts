// tests/features/analysis.test.ts — Tests for analysis feature reducer (Plan 161 Phase 4).

import { describe, it } from "vitest";
import { Effect } from "@pb/core";
import { createTestStore } from "../test-store.js";
import { analysisReducer, initialAnalysisState, type AnalysisEnv } from "@pb/platform";
import type { LiveProcedureRef } from "@pb/platform";

const mockEnv: AnalysisEnv = {
  getLiveProcedures: () => Effect.none(),
};

const items: LiveProcedureRef[] = [
  { object: "w_obj", proc_name: "proc_a" },
  { object: "w_obj", proc_name: "proc_b" },
];

describe("analysis reducer", () => {
  describe("analysis/load-live-procedures", () => {
    it("fires getLiveProcedures and populates state on load", () => {
      const env: AnalysisEnv = { ...mockEnv, getLiveProcedures: () => Effect.send(items) };
      const ts = createTestStore(analysisReducer, env, initialAnalysisState);
      ts.send({ tag: "load-live-procedures" }, () => {});
      ts.receive({ tag: "live-procedures-loaded", items }, (s) => {
        s.liveProcedures = items;
        s.liveProceduresLoaded = true;
      });
    });

    it("does nothing if already loaded", () => {
      const state = { ...initialAnalysisState, liveProcedures: items, liveProceduresLoaded: true };
      const ts = createTestStore(analysisReducer, mockEnv, state);
      ts.send({ tag: "load-live-procedures" }, () => {});
    });
  });
});
