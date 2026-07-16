// tests/features/analysis.test.ts — Tests for analysis feature reducer (Plan 161 Phase 4).

import { describe, it } from "vitest";
import { Effect } from "@pb/core";
import { createTestStore } from "../test-store.js";
import { analysisReducer, initialAnalysisState, type AnalysisEnv } from "@pb/platform";
import type { LiveProcedureRef, DeadVarFinding, TypeMismatchFinding } from "@pb/platform";

const mockEnv: AnalysisEnv = {
  getLiveProcedures: () => Effect.none(),
  getDeadVars: () => Effect.none(),
  getTypeMismatches: () => Effect.none(),
};

const items: LiveProcedureRef[] = [
  { object: "w_obj", proc_name: "proc_a" },
  { object: "w_obj", proc_name: "proc_b" },
];

const deadVarItems: DeadVarFinding[] = [
  { object: "w_obj", proc_name: "uf_save", var_name: "li_unused", line: 12, kind: "never-read" },
  { object: "w_obj", proc_name: "uf_save", var_name: "as_param", line: null, kind: "unused-param" },
];

const typeMismatchItems: TypeMismatchFinding[] = [
  { object: "w_obj", proc_name: "uf_save", line: 12, target: "ls_name", lhs_type: "string", rhs_desc: "an integer literal", kind: "assign-mismatch" },
  { object: "w_obj", proc_name: "uf_calc", line: 30, target: "uf_calc", lhs_type: "long", rhs_desc: "a string literal", kind: "return-mismatch" },
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

  describe("analysis/load-dead-vars", () => {
    it("fires getDeadVars and populates state on load", () => {
      const env: AnalysisEnv = { ...mockEnv, getDeadVars: () => Effect.send(deadVarItems) };
      const ts = createTestStore(analysisReducer, env, initialAnalysisState);
      ts.send({ tag: "load-dead-vars" }, () => {});
      ts.receive({ tag: "dead-vars-loaded", items: deadVarItems }, (s) => {
        s.deadVars = deadVarItems;
        s.deadVarsLoaded = true;
      });
    });

    it("does nothing if already loaded", () => {
      const state = { ...initialAnalysisState, deadVars: deadVarItems, deadVarsLoaded: true };
      const ts = createTestStore(analysisReducer, mockEnv, state);
      ts.send({ tag: "load-dead-vars" }, () => {});
    });
  });

  describe("analysis/load-type-mismatches", () => {
    it("fires getTypeMismatches and populates state on load", () => {
      const env: AnalysisEnv = { ...mockEnv, getTypeMismatches: () => Effect.send(typeMismatchItems) };
      const ts = createTestStore(analysisReducer, env, initialAnalysisState);
      ts.send({ tag: "load-type-mismatches" }, () => {});
      ts.receive({ tag: "type-mismatches-loaded", items: typeMismatchItems }, (s) => {
        s.typeMismatches = typeMismatchItems;
        s.typeMismatchesLoaded = true;
      });
    });

    it("does nothing if already loaded", () => {
      const state = { ...initialAnalysisState, typeMismatches: typeMismatchItems, typeMismatchesLoaded: true };
      const ts = createTestStore(analysisReducer, mockEnv, state);
      ts.send({ tag: "load-type-mismatches" }, () => {});
    });
  });
});
