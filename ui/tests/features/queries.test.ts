// tests/features/queries.test.ts — Tests for queries feature reducer.

import { describe, it, expect } from "vitest";
import { Effect } from "../../src/core/effect.js";
import { createTestStore } from "../test-store.js";
import { queriesReducer, initialQueriesState, type QueriesEnv } from "../../src/features/queries/reducer.js";
import type { QueriesState } from "../../src/features/queries/types.js";
import type { NavigationAction } from "../../src/features/navigation/types.js";

function makeMockEnv(): QueriesEnv & { lastNavigate: NavigationAction | null } {
  const env: QueriesEnv & { lastNavigate: NavigationAction | null } = {
    lastNavigate: null,
    getQueries: () => Effect.none(),
    runQuery: () => Effect.none(),
    navigate: (action) => { env.lastNavigate = action; return Effect.none(); },
  };
  return env;
}

describe("queries reducer", () => {
  describe("queries/loaded", () => {
    it("populates items and clears loading", () => {
      const items = [{ name: "top", description: "Most complex", params: [] }];
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ type: "loaded", items }, (s) => {
        s.items = items;
        s.loading = false;
      });
    });
  });

  describe("queries/run", () => {
    it("clears results, sets resultsName and queryParams", () => {
      const init: QueriesState = { ...initialQueriesState, results: { columns: [], rows: [{ x: 1 }] } };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ type: "run", name: "top", params: { n: "5" } }, (s) => {
        s.results = null;
        s.resultsName = "top";
        s.queryParams = { n: "5" };
      });
    });

    it("emits navigate to queries URL with queryName and params", () => {
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ type: "run", name: "top", params: { n: "5" } });
      expect(env.lastNavigate).toEqual({
        type: "navigate",
        route: { view: "queries", queryName: "top", queryParams: { n: "5" } },
      });
    });
  });

  describe("queries/result", () => {
    it("populates results and clears loading", () => {
      const data = { columns: [{ name: "obj", entity_type: null }], rows: [{ obj: "foo" }] };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ type: "result", data }, (s) => {
        s.results = data;
        s.loading = false;
      });
    });
  });

  describe("queries/restore", () => {
    it("skips re-run when resultsName matches and results are non-null", () => {
      const existing = {
        columns: [{ name: "obj", entity_type: null as string | null }],
        rows: [{ obj: "foo" }],
      };
      const init: QueriesState = {
        ...initialQueriesState,
        resultsName: "top",
        queryParams: { n: "5" },
        results: existing,
      };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ type: "restore", name: "top", params: { n: "5" } });
      expect(env.lastNavigate).toBeNull();
    });

    it("re-runs query when resultsName differs", () => {
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ type: "restore", name: "callers", params: { name: "f_proc" } }, (s) => {
        s.resultsName = "callers";
        s.queryParams = { name: "f_proc" };
      });
    });

    it("re-runs query when results are null even if name matches", () => {
      const init: QueriesState = { ...initialQueriesState, resultsName: "top", results: null };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ type: "restore", name: "top", params: {} }, (s) => {
        s.queryParams = {};
      });
    });
  });

  describe("queries/navigate-to-entity", () => {
    it("calls navigate-from-ask for object entity type", () => {
      const init: QueriesState = {
        ...initialQueriesState,
        resultsName: "top",
        queryParams: { n: "5" },
      };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ type: "navigate-to-entity", entityType: "object", entityName: "w_payment", objectName: null });
      expect(env.lastNavigate).toEqual({
        type: "navigate-from-ask",
        route: { view: "objectDetail", name: "w_payment" },
        queryName: "top",
        queryRoute: { view: "queries", queryName: "top", queryParams: { n: "5" } },
      });
    });

    it("constructs procedureDetail route from entityName + objectName", () => {
      const init: QueriesState = {
        ...initialQueriesState,
        resultsName: "callers",
        queryParams: { name: "f_validate" },
      };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({
        type: "navigate-to-entity",
        entityType: "procedure",
        entityName: "f_validate",
        objectName: "w_payment",
      });
      expect(env.lastNavigate).toEqual({
        type: "navigate-from-ask",
        route: { view: "procedureDetail", name: "w_payment", proc: "f_validate" },
        queryName: "callers",
        queryRoute: { view: "queries", queryName: "callers", queryParams: { name: "f_validate" } },
      });
    });

    it("constructs dwDetail route for datawindow entity type", () => {
      const init: QueriesState = { ...initialQueriesState, resultsName: "dw", queryParams: {} };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ type: "navigate-to-entity", entityType: "datawindow", entityName: "d_grid", objectName: null });
      expect(env.lastNavigate).toMatchObject({
        type: "navigate-from-ask",
        route: { view: "dwDetail", name: "d_grid" },
      });
    });

    it("constructs tableDetail route for table entity type", () => {
      const init: QueriesState = { ...initialQueriesState, resultsName: "sql_tables", queryParams: {} };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ type: "navigate-to-entity", entityType: "table", entityName: "accounts", objectName: null });
      expect(env.lastNavigate).toMatchObject({
        type: "navigate-from-ask",
        route: { view: "tableDetail", name: "accounts" },
      });
    });

    it("does nothing for unknown entity type", () => {
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ type: "navigate-to-entity", entityType: "unknown", entityName: "x", objectName: null });
      expect(env.lastNavigate).toBeNull();
    });
  });

  describe("queries/sort", () => {
    it("sets sortCol and defaults to asc", () => {
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ type: "sort", col: "name" }, (s) => {
        s.sortCol = "name";
        s.sortDir = "asc";
        s.page = 0;
      });
    });

    it("toggles to desc on same column", () => {
      const init: QueriesState = { ...initialQueriesState, sortCol: "name", sortDir: "asc" };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ type: "sort", col: "name" }, (s) => {
        s.sortDir = "desc";
        s.page = 0;
      });
    });

    it("toggles back to asc when already desc", () => {
      const init: QueriesState = { ...initialQueriesState, sortCol: "name", sortDir: "desc" };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ type: "sort", col: "name" }, (s) => {
        s.sortDir = "asc";
        s.page = 0;
      });
    });

    it("resets to asc and clears page on new column", () => {
      const init: QueriesState = { ...initialQueriesState, sortCol: "name", sortDir: "desc", page: 3 };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ type: "sort", col: "cyclomatic" }, (s) => {
        s.sortCol = "cyclomatic";
        s.sortDir = "asc";
        s.page = 0;
      });
    });
  });

  describe("queries/set-page", () => {
    it("sets page number", () => {
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ type: "set-page", page: 2 }, (s) => {
        s.page = 2;
      });
    });
  });
});
