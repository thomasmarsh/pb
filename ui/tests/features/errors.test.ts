// tests/features/errors.test.ts — Tests for errors feature reducer.

import { describe, it } from "vitest";
import { Effect } from "@pb/core";
import { createTestStore } from "../test-store.js";
import { errorsReducer, initialErrorsState, type ErrorsEnv, type TypeCoverageResponse } from "@pb/platform";

const mockEnv: ErrorsEnv = {
  getErrors: () => Effect.none(),
  getTypeCoverage: () => Effect.none(),
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
};

describe("errors reducer", () => {
  describe("errors/loaded", () => {
    it("populates items/total and clears loading", () => {
      const items = [
        { file: "a.srw", error_kind: "powerscript" as const, message: "lex error", object: null, proc_name: null, line: 3, snippet: "garble" },
      ];
      const ts = createTestStore(errorsReducer, mockEnv, initialErrorsState);
      ts.send({ tag: "loaded", items, total: 1 }, (s) => {
        s.items = items;
        s.total = 1;
        s.loading = false;
      });
    });
  });

  describe("errors/load", () => {
    it("fetches errors and type coverage in parallel", () => {
      const items = [
        { file: "a.srw", error_kind: "powerscript" as const, message: "lex error", object: null, proc_name: null, line: 3, snippet: "garble" },
      ];
      const env: ErrorsEnv = {
        getErrors: () => Effect.send({ items, total: 1, offset: 0, limit: 200 }),
        getTypeCoverage: () => Effect.send(MOCK_COVERAGE),
      };
      const ts = createTestStore(errorsReducer, env, initialErrorsState);
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

  describe("errors/typeCoverageLoaded", () => {
    it("sets typeCoverage", () => {
      const ts = createTestStore(errorsReducer, mockEnv, initialErrorsState);
      ts.send({ tag: "typeCoverageLoaded", data: MOCK_COVERAGE }, (s) => {
        s.typeCoverage = MOCK_COVERAGE;
      });
    });
  });

  describe("errors/typeCoverageError", () => {
    it("is a no-op on state (errors table stays usable even if coverage fails)", () => {
      const ts = createTestStore(errorsReducer, mockEnv, initialErrorsState);
      ts.send({ tag: "typeCoverageError", error: "boom" }, () => {
        /* no state change expected */
      });
    });
  });

  describe("errors/setFilterKind", () => {
    it("updates filterKind, resets page, and sets loading", () => {
      const ts = createTestStore(errorsReducer, mockEnv, { ...initialErrorsState, page: 3 });
      ts.send({ tag: "setFilterKind", kind: "sql" }, (s) => {
        s.filterKind = "sql";
        s.page = 0;
        s.loading = true;
      });
    });
  });

  describe("errors/setQuery", () => {
    it("updates query, resets page, and sets loading", () => {
      const ts = createTestStore(errorsReducer, mockEnv, { ...initialErrorsState, page: 2 });
      ts.send({ tag: "setQuery", query: "invalid" }, (s) => {
        s.query = "invalid";
        s.page = 0;
        s.loading = true;
      });
    });
  });

  describe("errors/setPage", () => {
    it("updates page and sets loading", () => {
      const ts = createTestStore(errorsReducer, mockEnv, initialErrorsState);
      ts.send({ tag: "setPage", page: 1 }, (s) => {
        s.page = 1;
        s.loading = true;
      });
    });
  });

  describe("errors/select", () => {
    it("sets the selected error", () => {
      const row = { file: "a.srw", error_kind: "sql" as const, message: "bad", object: "o", proc_name: "p", line: 1, snippet: "SELECT" };
      const ts = createTestStore(errorsReducer, mockEnv, initialErrorsState);
      ts.send({ tag: "select", row }, (s) => {
        s.selected = row;
      });
    });
  });
});
