// tests/features/analysis.test.ts — Tests for analysis feature reducer (Plan 161 Phase 4).

import { describe, it } from "vitest";
import { Effect } from "@pb/core";
import { createTestStore } from "../test-store.js";
import { analysisReducer, initialAnalysisState, type AnalysisEnv } from "@pb/platform";
import type { LiveProcedureRef, DeadVarFinding, TypeMismatchFinding, CapabilityCatalogItem, CapabilityProcedureRef } from "@pb/platform";

const mockEnv: AnalysisEnv = {
  getLiveProcedures: () => Effect.none(),
  getDeadVars: () => Effect.none(),
  getTypeMismatches: () => Effect.none(),
  getCapabilities: () => Effect.none(),
  getCapabilityProcedures: () => Effect.none(),
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

const capabilityItems: CapabilityCatalogItem[] = [
  { capability: "DB", proc_count: 3 },
  { capability: "UI", proc_count: 1 },
];

const capabilityProcItems: CapabilityProcedureRef[] = [
  { object: "w_obj", proc_name: "proc_a" },
  { object: "w_obj", proc_name: "proc_c" },
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

  describe("analysis/load-capabilities", () => {
    it("fires getCapabilities and populates state on load", () => {
      const env: AnalysisEnv = { ...mockEnv, getCapabilities: () => Effect.send(capabilityItems) };
      const ts = createTestStore(analysisReducer, env, initialAnalysisState);
      ts.send({ tag: "load-capabilities" }, () => {});
      ts.receive({ tag: "capabilities-loaded", items: capabilityItems }, (s) => {
        s.capabilities = capabilityItems;
        s.capabilitiesLoaded = true;
      });
    });

    it("does nothing if already loaded", () => {
      const state = { ...initialAnalysisState, capabilities: capabilityItems, capabilitiesLoaded: true };
      const ts = createTestStore(analysisReducer, mockEnv, state);
      ts.send({ tag: "load-capabilities" }, () => {});
    });
  });

  describe("analysis/load-capability-procedures", () => {
    it("fires getCapabilityProcedures and populates state on load", () => {
      const env: AnalysisEnv = { ...mockEnv, getCapabilityProcedures: () => Effect.send(capabilityProcItems) };
      const ts = createTestStore(analysisReducer, env, initialAnalysisState);
      ts.send({ tag: "load-capability-procedures", capability: "DB" }, () => {});
      ts.receive({ tag: "capability-procedures-loaded", capability: "DB", items: capabilityProcItems }, (s) => {
        s.capabilityProcedures = { DB: capabilityProcItems };
      });
    });

    it("does nothing if that capability's procedures are already loaded", () => {
      const state = { ...initialAnalysisState, capabilityProcedures: { DB: capabilityProcItems } };
      const ts = createTestStore(analysisReducer, mockEnv, state);
      ts.send({ tag: "load-capability-procedures", capability: "DB" }, () => {});
    });

    it("loads a second capability's procedures independently, keeping the first cached", () => {
      const env: AnalysisEnv = { ...mockEnv, getCapabilityProcedures: () => Effect.send([{ object: "w_obj", proc_name: "proc_b" }]) };
      const state = { ...initialAnalysisState, capabilityProcedures: { DB: capabilityProcItems } as Record<string, CapabilityProcedureRef[]> };
      const ts = createTestStore(analysisReducer, env, state);
      ts.send({ tag: "load-capability-procedures", capability: "UI" }, () => {});
      ts.receive({ tag: "capability-procedures-loaded", capability: "UI", items: [{ object: "w_obj", proc_name: "proc_b" }] }, (s) => {
        s.capabilityProcedures = { DB: capabilityProcItems, UI: [{ object: "w_obj", proc_name: "proc_b" }] };
      });
    });
  });
});
