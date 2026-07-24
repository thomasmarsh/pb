// tests/features/diagnostics.test.ts — Tests for diagnostics feature reducer.

import { describe, it } from "vitest";
import { Effect } from "@pb/core";
import { createTestStore } from "../test-store.js";
import { diagnosticsReducer, initialDiagnosticsState, type DiagnosticsEnv, type TypeCoverageResponse } from "@pb/platform";

const mockEnv: DiagnosticsEnv = {
  getDiagnostics: () => Effect.none(),
  getTypeCoverage: () => Effect.none(),
  getDiagnosticsTimeline: (_z: number) => Effect.none(),
};

const MOCK_COVERAGE: TypeCoverageResponse = {
  total_identifier_tokens: 100,
  resolved_identifier_tokens: 80,
  token_coverage_pct: 80,
  var_ref_total: 50,
  var_ref_resolved: 48,
  var_ref_pct: 96,
  call_total: 30,
  call_resolved: 29,
  call_pct: 96.67,
  var_ref_kind_counts: [{ kind: "local", count: 40 }, { kind: "unresolved", count: 2 }],
  call_kind_counts: [{ kind: "virtual", count: 29 }, { kind: "unresolved", count: 1 }],
  var_ref_kind_confidence_counts: [
    { kind: "local", confidence: "high", count: 40 },
    { kind: "unresolved", confidence: "unresolved", count: 2 },
  ],
  call_kind_confidence_counts: [
    { kind: "virtual", confidence: "high", count: 29 },
    { kind: "unresolved", confidence: "unresolved", count: 1 },
  ],
};

describe("diagnostics reducer", () => {
  describe("diagnostics/loaded", () => {
    it("populates items/total and clears loading", () => {
      const items = [
        { file: "a.srw", error_kind: "powerscript" as const, message: "lex error", object: null, proc_name: null, line: 3, snippet: "garble" },
      ];
      const ts = createTestStore(diagnosticsReducer, mockEnv, initialDiagnosticsState);
      ts.send({ tag: "loaded", items, total: 1 }, (s) => {
        s.items = items;
        s.total = 1;
        s.loading = false;
      });
    });
  });

  describe("diagnostics/load", () => {
    it("fetches diagnostics and type coverage in parallel", () => {
      const items = [
        { file: "a.srw", error_kind: "powerscript" as const, message: "lex error", object: null, proc_name: null, line: 3, snippet: "garble" },
      ];
      const env: DiagnosticsEnv = {
        getDiagnostics: () => Effect.send({ items, total: 1, offset: 0, limit: 200 }),
        getTypeCoverage: () => Effect.send(MOCK_COVERAGE),
        getDiagnosticsTimeline: (_z: number) => Effect.none(),
      };
      const ts = createTestStore(diagnosticsReducer, env, initialDiagnosticsState);
      ts.send({ tag: "load" }, (s) => {
        s.loading = true;
      });
      ts.receive({ tag: "loaded", items, total: 1 }, (s) => {
        s.items = items;
        s.total = 1;
        s.loading = false;
      });
      ts.receive({ tag: "typeCoverageLoaded", data: MOCK_COVERAGE }, (s) => {
        s.typeCoverage = MOCK_COVERAGE;
      });
    });
  });

  describe("diagnostics/typeCoverageLoaded", () => {
    it("sets typeCoverage", () => {
      const ts = createTestStore(diagnosticsReducer, mockEnv, initialDiagnosticsState);
      ts.send({ tag: "typeCoverageLoaded", data: MOCK_COVERAGE }, (s) => {
        s.typeCoverage = MOCK_COVERAGE;
      });
    });
  });

  describe("diagnostics/typeCoverageError", () => {
    it("is a no-op on state (diagnostics table stays usable even if coverage fails)", () => {
      const ts = createTestStore(diagnosticsReducer, mockEnv, initialDiagnosticsState);
      ts.send({ tag: "typeCoverageError", error: "boom" }, () => {
        /* no state change expected */
      });
    });
  });

  describe("diagnostics/setFilterKind", () => {
    it("updates filterKind, resets page, and sets loading", () => {
      const ts = createTestStore(diagnosticsReducer, mockEnv, { ...initialDiagnosticsState, page: 3 });
      ts.send({ tag: "setFilterKind", kind: "sql" }, (s) => {
        s.filterKind = "sql";
        s.page = 0;
        s.loading = true;
      });
    });
  });

  describe("diagnostics/setQuery", () => {
    it("updates query, resets page, and sets loading", () => {
      const ts = createTestStore(diagnosticsReducer, mockEnv, { ...initialDiagnosticsState, page: 2 });
      ts.send({ tag: "setQuery", query: "invalid" }, (s) => {
        s.query = "invalid";
        s.page = 0;
        s.loading = true;
      });
    });
  });

  describe("diagnostics/setPage", () => {
    it("updates page and sets loading", () => {
      const ts = createTestStore(diagnosticsReducer, mockEnv, initialDiagnosticsState);
      ts.send({ tag: "setPage", page: 1 }, (s) => {
        s.page = 1;
        s.loading = true;
      });
    });
  });

  describe("diagnostics/select", () => {
    it("sets the selected error", () => {
      const row = { file: "a.srw", error_kind: "sql" as const, message: "bad", object: "o", proc_name: "p", line: 1, snippet: "SELECT" };
      const ts = createTestStore(diagnosticsReducer, mockEnv, initialDiagnosticsState);
      ts.send({ tag: "select", row }, (s) => {
        s.selected = row;
      });
    });
  });
});
