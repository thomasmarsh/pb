// tests/features/errors.test.ts — Tests for errors feature reducer.

import { describe, it } from "vitest";
import { Effect } from "../../src/core/effect.js";
import { createTestStore } from "../test-store.js";
import { errorsReducer, initialErrorsState, type ErrorsEnv } from "../../src/features/errors/reducer.js";

const mockEnv: ErrorsEnv = {
  getErrors: () => Effect.none(),
};

describe("errors reducer", () => {
  describe("errors/loaded", () => {
    it("populates items/total and clears loading", () => {
      const items = [
        { file: "a.srw", error_kind: "powerscript" as const, message: "lex error", object: null, proc_name: null, line: 3, snippet: "garble" },
      ];
      const ts = createTestStore(errorsReducer, mockEnv, initialErrorsState);
      ts.send({ type: "loaded", items, total: 1 }, (s) => {
        s.items = items;
        s.total = 1;
        s.loading = false;
      });
    });
  });

  describe("errors/setFilterKind", () => {
    it("updates filterKind, resets page, and sets loading", () => {
      const ts = createTestStore(errorsReducer, mockEnv, { ...initialErrorsState, page: 3 });
      ts.send({ type: "setFilterKind", kind: "sql" }, (s) => {
        s.filterKind = "sql";
        s.page = 0;
        s.loading = true;
      });
    });
  });

  describe("errors/setQuery", () => {
    it("updates query, resets page, and sets loading", () => {
      const ts = createTestStore(errorsReducer, mockEnv, { ...initialErrorsState, page: 2 });
      ts.send({ type: "setQuery", query: "invalid" }, (s) => {
        s.query = "invalid";
        s.page = 0;
        s.loading = true;
      });
    });
  });

  describe("errors/setPage", () => {
    it("updates page and sets loading", () => {
      const ts = createTestStore(errorsReducer, mockEnv, initialErrorsState);
      ts.send({ type: "setPage", page: 1 }, (s) => {
        s.page = 1;
        s.loading = true;
      });
    });
  });

  describe("errors/select", () => {
    it("sets the selected error", () => {
      const row = { file: "a.srw", error_kind: "sql" as const, message: "bad", object: "o", proc_name: "p", line: 1, snippet: "SELECT" };
      const ts = createTestStore(errorsReducer, mockEnv, initialErrorsState);
      ts.send({ type: "select", row }, (s) => {
        s.selected = row;
      });
    });
  });
});
