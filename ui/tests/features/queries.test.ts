// tests/features/queries.test.ts — Tests for queries feature reducer.

import { describe, it, expect } from "vitest";
import { Effect } from "@pb/core";
import { createTestStore } from "../test-store.js";
import { queriesReducer, initialQueriesState, type QueriesEnv } from "../../src/features/queries/reducer.js";
import type { QueriesState } from "../../src/features/queries/types.js";
import type { NavigationAction } from "../../src/features/navigation/types.js";

function makeMockEnv(): QueriesEnv & { lastNavigate: NavigationAction | null; lastSql: string | null } {
  const env: QueriesEnv & { lastNavigate: NavigationAction | null; lastSql: string | null } = {
    lastNavigate: null,
    lastSql: null,
    getQueries: () => Effect.none(),
    runQuery: () => Effect.none(),
    runSql: (sql) => { env.lastSql = sql; return Effect.none(); },
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
      ts.send({ tag: "loaded", items }, (s) => {
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
      ts.send({ tag: "run", name: "top", params: { n: "5" } }, (s) => {
        s.results = null;
        s.resultsName = "top";
        s.queryParams = { n: "5" };
      });
    });

    it("emits navigate to queries URL with queryName and params", () => {
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "run", name: "top", params: { n: "5" } });
      expect(env.lastNavigate).toEqual({
        tag: "navigate",
        route: { view: "queries", queryName: "top", queryParams: { n: "5" } },
      });
    });
  });

  describe("queries/result", () => {
    it("populates results and clears loading", () => {
      const data = { columns: [{ name: "obj", entity_type: null }], rows: [{ obj: "foo" }] };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "result", data }, (s) => {
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
      ts.send({ tag: "restore", name: "top", params: { n: "5" } });
      expect(env.lastNavigate).toBeNull();
    });

    it("re-runs query when resultsName differs", () => {
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "restore", name: "callers", params: { name: "f_proc" } }, (s) => {
        s.resultsName = "callers";
        s.queryParams = { name: "f_proc" };
      });
    });

    it("re-runs query when results are null even if name matches", () => {
      const init: QueriesState = { ...initialQueriesState, resultsName: "top", results: null };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "restore", name: "top", params: {} }, (s) => {
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
      ts.send({ tag: "navigate-to-entity", entityType: "object", entityName: "w_payment", objectName: null });
      expect(env.lastNavigate).toEqual({
        tag: "navigate-from-ask",
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
        tag: "navigate-to-entity",
        entityType: "procedure",
        entityName: "f_validate",
        objectName: "w_payment",
      });
      expect(env.lastNavigate).toEqual({
        tag: "navigate-from-ask",
        route: { view: "procedureDetail", name: "w_payment", proc: "f_validate" },
        queryName: "callers",
        queryRoute: { view: "queries", queryName: "callers", queryParams: { name: "f_validate" } },
      });
    });

    it("constructs dwDetail route for datawindow entity type", () => {
      const init: QueriesState = { ...initialQueriesState, resultsName: "dw", queryParams: {} };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "navigate-to-entity", entityType: "datawindow", entityName: "d_grid", objectName: null });
      expect(env.lastNavigate).toMatchObject({
        tag: "navigate-from-ask",
        route: { view: "dwDetail", name: "d_grid" },
      });
    });

    it("constructs tableDetail route for table entity type", () => {
      const init: QueriesState = { ...initialQueriesState, resultsName: "sql_tables", queryParams: {} };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "navigate-to-entity", entityType: "table", entityName: "accounts", objectName: null });
      expect(env.lastNavigate).toMatchObject({
        tag: "navigate-from-ask",
        route: { view: "tableDetail", name: "accounts" },
      });
    });

    it("does nothing for unknown entity type", () => {
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "navigate-to-entity", entityType: "unknown", entityName: "x", objectName: null });
      expect(env.lastNavigate).toBeNull();
    });

    it("in SQL mode uses sqlText queryRoute", () => {
      const sql = "SELECT name FROM objects";
      const init: QueriesState = {
        ...initialQueriesState,
        resultsName: "SELECT name FROM ob",
        generatedSql: sql,
        isSqlMode: true,
      };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "navigate-to-entity", entityType: "object", entityName: "w_pay", objectName: null });
      expect(env.lastNavigate).toMatchObject({
        tag: "navigate-from-ask",
        route: { view: "objectDetail", name: "w_pay" },
        queryRoute: { view: "queries", sqlText: sql },
      });
    });
  });

  describe("queries/sort", () => {
    it("sets sortCol and defaults to asc", () => {
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "sort", col: "name" }, (s) => {
        s.sortCol = "name";
        s.sortDir = "asc";
        s.page = 0;
      });
    });

    it("toggles to desc on same column", () => {
      const init: QueriesState = { ...initialQueriesState, sortCol: "name", sortDir: "asc" };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "sort", col: "name" }, (s) => {
        s.sortDir = "desc";
        s.page = 0;
      });
    });

    it("toggles back to asc when already desc", () => {
      const init: QueriesState = { ...initialQueriesState, sortCol: "name", sortDir: "desc" };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "sort", col: "name" }, (s) => {
        s.sortDir = "asc";
        s.page = 0;
      });
    });

    it("resets to asc and clears page on new column", () => {
      const init: QueriesState = { ...initialQueriesState, sortCol: "name", sortDir: "desc", page: 3 };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "sort", col: "cyclomatic" }, (s) => {
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
      ts.send({ tag: "set-page", page: 2 }, (s) => {
        s.page = 2;
      });
    });
  });

  // ── AskInput free-text actions ─────────────────────────────────────────────

  describe("queries/set-ask-text", () => {
    it("updates askText", () => {
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "set-ask-text", text: "SELECT name FROM objects" }, (s) => {
        s.askText = "SELECT name FROM objects";
      });
    });
  });

  describe("queries/toggle-query-pane", () => {
    it("opens pane when closed", () => {
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "toggle-query-pane" }, (s) => {
        s.queryPaneOpen = true;
      });
    });

    it("closes pane when open", () => {
      const init: QueriesState = { ...initialQueriesState, queryPaneOpen: true };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "toggle-query-pane" }, (s) => {
        s.queryPaneOpen = false;
      });
    });
  });

  describe("queries/set-generated-sql", () => {
    it("updates generatedSql", () => {
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "set-generated-sql", sql: "SELECT 1" }, (s) => {
        s.generatedSql = "SELECT 1";
      });
    });
  });

  describe("queries/run-sql", () => {
    it("sets generatedSql, resultsName (truncated), isSqlMode, clears results", () => {
      const sql = "SELECT name, object FROM procedures ORDER BY cyclomatic DESC LIMIT 20";
      const init: QueriesState = { ...initialQueriesState, results: { columns: [], rows: [] } };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "run-sql", sql }, (s) => {
        s.generatedSql = sql;
        s.resultsName = sql.slice(0, 50);
        s.isSqlMode = true;
        s.results = null;
        s.page = 0;
        s.loading = true;
        s.recentQueries = [sql];
      });
    });

    it("pushes to recentQueries (most-recent first, max 5)", () => {
      const existing = ["q1", "q2", "q3", "q4", "q5"];
      const init: QueriesState = { ...initialQueriesState, recentQueries: existing };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "run-sql", sql: "SELECT 1" }, (s) => {
        s.generatedSql = "SELECT 1";
        s.resultsName = "SELECT 1";
        s.isSqlMode = true;
        s.results = null;
        s.page = 0;
        s.loading = true;
        s.recentQueries = ["SELECT 1", "q1", "q2", "q3", "q4"];
      });
    });

    it("does not duplicate the same query at the front", () => {
      const init: QueriesState = { ...initialQueriesState, recentQueries: ["SELECT 1", "q2"] };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "run-sql", sql: "SELECT 1" }, (s) => {
        s.generatedSql = "SELECT 1";
        s.resultsName = "SELECT 1";
        s.isSqlMode = true;
        s.results = null;
        s.page = 0;
        s.loading = true;
        s.recentQueries = ["SELECT 1", "q2"];
      });
    });

    it("navigates to queries route with sqlText", () => {
      const sql = "SELECT name FROM objects";
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "run-sql", sql });
      expect(env.lastNavigate).toEqual({
        tag: "navigate",
        route: { view: "queries", sqlText: sql },
      });
    });

    it("calls env.runSql with the sql", () => {
      const sql = "SELECT name FROM objects";
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "run-sql", sql });
      expect(env.lastSql).toBe(sql);
    });

    it("on failure: sets error and opens query pane", async () => {
      const sql = "SELECT invalid";
      const env: QueriesEnv & { lastNavigate: NavigationAction | null; lastSql: string | null } = {
        lastNavigate: null,
        lastSql: null,
        getQueries: () => Effect.none(),
        runQuery: () => Effect.none(),
        runSql: () => Effect.fromPromise(() => Promise.reject(new Error("syntax error"))),
        navigate: (action) => { env.lastNavigate = action; return Effect.none(); },
      };
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "run-sql", sql });
      await ts.drain();
      ts.receive({ tag: "error", error: "Error: syntax error" }, (s) => {
        s.results = { error: "Error: syntax error" };
        s.loading = false;
        s.queryPaneOpen = true;
      });
    });
  });

  describe("queries/submit-ask", () => {
    it("SQL input (SELECT prefix) dispatches run-sql", () => {
      const init: QueriesState = { ...initialQueriesState, askText: "SELECT name FROM objects" };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "submit-ask" });
      expect(env.lastSql).toBe("SELECT name FROM objects");
    });

    it("SQL detection is case-insensitive", () => {
      const init: QueriesState = { ...initialQueriesState, askText: "select name from objects" };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "submit-ask" });
      expect(env.lastSql).toBe("select name from objects");
    });

    it("WITH prefix also routes to SQL", () => {
      const init: QueriesState = { ...initialQueriesState, askText: "WITH cte AS (SELECT 1) SELECT * FROM cte" };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "submit-ask" });
      expect(env.lastSql).not.toBeNull();
    });

    it("NL input sets error result (no LLM at P1)", () => {
      const init: QueriesState = { ...initialQueriesState, askText: "which procedures call f_validate?" };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "submit-ask" }, (s) => {
        s.results = { error: expect.stringContaining("SELECT") as unknown as string };
      });
      expect(env.lastSql).toBeNull();
    });

    it("empty askText does nothing", () => {
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "submit-ask" });
      expect(env.lastSql).toBeNull();
      expect(env.lastNavigate).toBeNull();
    });
  });

  describe("queries/run-recent", () => {
    it("re-runs a SQL query from the recent strip", () => {
      const sql = "SELECT name FROM objects";
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "run-recent", text: sql }, (s) => {
        s.askText = sql;
        s.generatedSql = sql;
        s.resultsName = sql.slice(0, 50);
        s.isSqlMode = true;
        s.results = null;
        s.page = 0;
        s.loading = true;
        s.recentQueries = [sql];
      });
      expect(env.lastSql).toBe(sql);
    });
  });
});
