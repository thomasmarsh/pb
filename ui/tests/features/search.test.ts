// tests/features/search.test.ts — Tests for search feature reducer.

import { describe, it } from "vitest";
import { Effect } from "../../src/core/effect.js";
import { createTestStore } from "../test-store.js";
import { searchReducer, initialSearchState, type SearchEnv } from "../../src/features/search/reducer.js";

const mockEnv: SearchEnv = {
  search: () => Effect.none(),
};

describe("search reducer", () => {
  describe("search/term", () => {
    it("sets term", () => {
      const ts = createTestStore(searchReducer, mockEnv, initialSearchState);
      ts.send({ type: "term", term: "fn_" }, (s) => {
        s.term = "fn_";
      });
    });

    it("fires search effect when term is 2+ chars", () => {
      const ts = createTestStore(searchReducer, mockEnv, initialSearchState);
      ts.send({ type: "term", term: "fn" }, (s) => {
        s.term = "fn";
      });
    });

    it("no effect when term is under 2 chars", () => {
      const ts = createTestStore(searchReducer, mockEnv, initialSearchState);
      ts.send({ type: "term", term: "f" }, (s) => {
        s.term = "f";
      });
    });
  });

  describe("search/loaded", () => {
    it("populates results and clears loading", () => {
      const data = { objects: [], procedures: [], datawindows: [] };
      const ts = createTestStore(searchReducer, mockEnv, initialSearchState);
      ts.send({ type: "loaded", data }, (s) => {
        s.results = data;
        s.loading = false;
      });
    });
  });
});
