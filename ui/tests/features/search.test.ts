// tests/features/search.test.ts — Tests for search feature reducer.

import { describe, it, expect } from "vitest";
import { Effect } from "../../src/core/effect.js";
import { createTestStore } from "../test-store.js";
import { searchReducer, initialSearchState, type SearchEnv } from "../../src/features/search/reducer.js";
import type { SearchState } from "../../src/features/search/types.js";

const mockEnv: SearchEnv = {
  search: () => Effect.none(),
  navigate: () => Effect.none(),
};

describe("search reducer", () => {
  describe("search/term", () => {
    it("sets term", () => {
      const ts = createTestStore(searchReducer, mockEnv, initialSearchState);
      ts.send({ tag: "term", term: "fn_" }, (s) => {
        s.term = "fn_";
        s.recentSearches = ["fn_"];
      });
    });

    it("fires search effect when term is 2+ chars", () => {
      const ts = createTestStore(searchReducer, mockEnv, initialSearchState);
      ts.send({ tag: "term", term: "fn" }, (s) => {
        s.term = "fn";
        s.recentSearches = ["fn"];
      });
    });

    it("no effect when term is under 2 chars", () => {
      const ts = createTestStore(searchReducer, mockEnv, initialSearchState);
      ts.send({ tag: "term", term: "f" }, (s) => {
        s.term = "f";
      });
    });

    it("adds term to recentSearches when 2+ chars", () => {
      const ts = createTestStore(searchReducer, mockEnv, initialSearchState);
      ts.send({ tag: "term", term: "fn_pay" }, (s) => {
        s.term = "fn_pay";
        s.recentSearches = ["fn_pay"];
      });
    });

    it("does not add to recentSearches when under 2 chars", () => {
      const ts = createTestStore(searchReducer, mockEnv, initialSearchState);
      ts.send({ tag: "term", term: "f" }, (s) => {
        s.term = "f";
      });
    });

    it("deduplicates recent searches, newest first", () => {
      const ts = createTestStore(searchReducer, mockEnv, initialSearchState);
      ts.send({ tag: "term", term: "fn_a" }, (s) => {
        s.term = "fn_a";
        s.recentSearches = ["fn_a"];
      });
      ts.send({ tag: "term", term: "fn_b" }, (s) => {
        s.term = "fn_b";
        s.recentSearches = ["fn_b", "fn_a"];
      });
      ts.send({ tag: "term", term: "fn_a" }, (s) => {
        s.term = "fn_a";
        s.recentSearches = ["fn_a", "fn_b"];
      });
    });

    it("caps recentSearches at 5 entries", () => {
      const ts = createTestStore(searchReducer, mockEnv, initialSearchState);
      for (let i = 0; i < 7; i++) {
        ts.send({ tag: "term", term: `fn_${i}` });
      }
      ts.send({ tag: "term", term: "final" }, (s) => {
        s.term = "final";
        s.recentSearches = ["final", "fn_6", "fn_5", "fn_4", "fn_3"];
      });
    });
  });

  describe("search/loaded", () => {
    it("populates results and clears loading", () => {
      const data = { objects: [], procedures: [], datawindows: [], tables: [] };
      const ts = createTestStore(searchReducer, mockEnv, initialSearchState);
      ts.send({ tag: "loaded", data }, (s) => {
        s.results = data;
        s.loading = false;
      });
    });
  });

  describe("overlay actions", () => {
    it("overlay-open sets overlayOpen and resets term/results", () => {
      const startState: SearchState = { ...initialSearchState, overlayTerm: "old", overlayResults: { objects: [], procedures: [], datawindows: [], tables: [] } };
      const ts = createTestStore(searchReducer, mockEnv, startState);
      ts.send({ tag: "overlay-open" }, (s) => {
        s.overlayOpen = true;
        s.overlayTerm = "";
        s.overlayResults = null;
      });
    });

    it("overlay-close clears overlayOpen", () => {
      const ts = createTestStore(searchReducer, mockEnv, { ...initialSearchState, overlayOpen: true });
      ts.send({ tag: "overlay-close" }, (s) => {
        s.overlayOpen = false;
      });
    });

    it("overlay-term fires search effect when 2+ chars", () => {
      let searchCalled = false;
      const env: SearchEnv = {
        search: (_q) => { searchCalled = true; return Effect.none(); },
        navigate: () => Effect.none(),
      };
      const ts = createTestStore(searchReducer, env, initialSearchState);
      ts.send({ tag: "overlay-term", term: "fn" });
      expect(searchCalled).toBe(true);
    });

    it("overlay-term clears results when under 2 chars", () => {
      const startState: SearchState = { ...initialSearchState, overlayResults: { objects: [], procedures: [], datawindows: [], tables: [] } };
      const ts = createTestStore(searchReducer, mockEnv, startState);
      ts.send({ tag: "overlay-term", term: "f" }, (s) => {
        s.overlayTerm = "f";
        s.overlayResults = null;
      });
    });

    it("overlay-loaded populates overlayResults", () => {
      const data = { objects: [], procedures: [], datawindows: [], tables: [] };
      const ts = createTestStore(searchReducer, mockEnv, initialSearchState);
      ts.send({ tag: "overlay-loaded", data }, (s) => {
        s.overlayResults = data;
        s.overlayLoading = false;
      });
    });
  });
});
