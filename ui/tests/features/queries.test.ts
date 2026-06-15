// tests/features/queries.test.ts — Tests for queries feature reducer.

import { describe, it } from "vitest";
import { Effect } from "../../src/core/effect.js";
import { createTestStore } from "../test-store.js";
import { queriesReducer, type QueriesEnv } from "../../src/features/queries/reducer.js";

const mockEnv: QueriesEnv = {
  getQueries: () => Effect.none(),
  runQuery: () => Effect.none(),
};

describe("queries reducer", () => {
  describe("queries/loaded", () => {
    it("populates items and clears loading", () => {
      const items = [{ name: "top", description: "Most complex", params: [] }];
      const ts = createTestStore(queriesReducer, mockEnv, queriesReducer.initialState());
      ts.send({ type: "loaded", items }, (s) => {
        s.items = items;
        s.loading = false;
      });
    });
  });

  describe("queries/run", () => {
    it("clears results and sets resultsName", () => {
      const init = { ...queriesReducer.initialState(), results: { columns: [], rows: [{ x: 1 }] } };
      const ts = createTestStore(queriesReducer, mockEnv, init);
      ts.send({ type: "run", name: "top", params: { n: "5" } }, (s) => {
        s.results = null;
        s.resultsName = "top";
      });
    });
  });

  describe("queries/result", () => {
    it("populates results and clears loading", () => {
      const data = { columns: ["obj"], rows: [{ obj: "foo" }] };
      const ts = createTestStore(queriesReducer, mockEnv, queriesReducer.initialState());
      ts.send({ type: "result", data }, (s) => {
        s.results = data;
        s.loading = false;
      });
    });
  });
});
