// tests/features/queries.test.ts — Tests for queries feature reducer.

import { describe, it, expect } from "vitest";
import { Effect } from "@pb/core";
import { createTestStore } from "../test-store.js";
import { queriesReducer, initialQueriesState, ASK_RUN_KEY, type QueriesEnv } from "@pb/platform";
import type { QueriesState, QueryRunState } from "@pb/platform";
import type { NavigationAction } from "@pb/platform";

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

function emptyRun(overrides: Partial<QueryRunState> = {}): QueryRunState {
  return { results: null, queryParams: {}, sql: null, sortCol: null, sortDir: "asc", page: 0, loading: false, ...overrides };
}

describe("queries reducer", () => {
  describe("queries/loaded", () => {
    it("populates items and clears itemsLoading", () => {
      const items = [{ name: "top", description: "Most complex", params: [] }];
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "loaded", items }, (s) => {
        s.items = items;
        s.itemsLoading = false;
      });
    });
  });

  describe("queries/run", () => {
    it("creates a fresh run keyed by query name, marked loading", () => {
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "run", name: "top", params: { n: "5" } }, (s) => {
        s.runs = { top: emptyRun({ queryParams: { n: "5" }, loading: true }) };
      });
    });

    it("does not disturb another query's existing run", () => {
      const init: QueriesState = {
        ...initialQueriesState,
        runs: { other: emptyRun({ results: { columns: [], rows: [{ x: 1 }] } }) },
      };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "run", name: "top", params: {} }, (s) => {
        s.runs = {
          other: emptyRun({ results: { columns: [], rows: [{ x: 1 }] } }),
          top: emptyRun({ loading: true }),
        };
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
    it("populates the run's results and clears its loading, keyed by action.key", () => {
      const data = { columns: [{ name: "obj", entity_type: null }], rows: [{ obj: "foo" }] };
      const init: QueriesState = { ...initialQueriesState, runs: { top: emptyRun({ loading: true }) } };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "result", key: "top", data }, (s) => {
        s.runs = { top: emptyRun({ results: data, loading: false }) };
      });
    });
  });

  describe("queries/error", () => {
    it("sets the run's results to an error and clears loading", () => {
      const init: QueriesState = { ...initialQueriesState, runs: { top: emptyRun({ loading: true }) } };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "error", key: "top", error: "boom" }, (s) => {
        s.runs = { top: emptyRun({ results: { error: "boom" }, loading: false }) };
      });
    });

    it("opens the query pane only when the erroring run is the Ask run", () => {
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "error", key: ASK_RUN_KEY, error: "boom" }, (s) => {
        s.runs = { [ASK_RUN_KEY]: emptyRun({ results: { error: "boom" } }) };
        s.queryPaneOpen = true;
      });
    });

    it("does not open the query pane for a catalogue query error", () => {
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "error", key: "top", error: "boom" }, (s) => {
        s.runs = { top: emptyRun({ results: { error: "boom" } }) };
      });
    });
  });

  describe("queries/restore", () => {
    it("skips re-run when the run exists and has non-null results", () => {
      const existing = {
        columns: [{ name: "obj", entity_type: null as string | null }],
        rows: [{ obj: "foo" }],
      };
      const init: QueriesState = {
        ...initialQueriesState,
        runs: { top: emptyRun({ queryParams: { n: "5" }, results: existing }) },
      };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "restore", name: "top", params: { n: "5" } });
      expect(env.lastNavigate).toBeNull();
    });

    it("re-runs query when no run exists yet", () => {
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "restore", name: "callers", params: { name: "f_proc" } }, (s) => {
        s.runs = { callers: emptyRun({ queryParams: { name: "f_proc" } }) };
      });
    });

    it("re-runs query when results are null even if the run exists", () => {
      const init: QueriesState = { ...initialQueriesState, runs: { top: emptyRun() } };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "restore", name: "top", params: {} }, (s) => {
        s.runs = { top: emptyRun() };
      });
    });
  });

  describe("queries/navigate-to-entity", () => {
    it("calls navigate-from-ask for object entity type, using the run's queryParams", () => {
      const init: QueriesState = {
        ...initialQueriesState,
        runs: { top: emptyRun({ queryParams: { n: "5" } }) },
      };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "navigate-to-entity", key: "top", entityType: "object", entityName: "w_payment", objectName: null });
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
        runs: { callers: emptyRun({ queryParams: { name: "f_validate" } }) },
      };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({
        tag: "navigate-to-entity",
        key: "callers",
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
      const init: QueriesState = { ...initialQueriesState, runs: { dw: emptyRun() } };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "navigate-to-entity", key: "dw", entityType: "datawindow", entityName: "d_grid", objectName: null });
      expect(env.lastNavigate).toMatchObject({
        tag: "navigate-from-ask",
        route: { view: "dwDetail", name: "d_grid" },
      });
    });

    it("constructs tableDetail route for table entity type", () => {
      const init: QueriesState = { ...initialQueriesState, runs: { sql_tables: emptyRun() } };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "navigate-to-entity", key: "sql_tables", entityType: "table", entityName: "accounts", objectName: null });
      expect(env.lastNavigate).toMatchObject({
        tag: "navigate-from-ask",
        route: { view: "tableDetail", name: "accounts" },
      });
    });

    it("does nothing for unknown entity type", () => {
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "navigate-to-entity", key: "top", entityType: "unknown", entityName: "x", objectName: null });
      expect(env.lastNavigate).toBeNull();
    });

    it("for the Ask run key, uses the sqlText queryRoute", () => {
      const sql = "SELECT name FROM objects";
      const init: QueriesState = {
        ...initialQueriesState,
        runs: { [ASK_RUN_KEY]: emptyRun({ sql }) },
      };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "navigate-to-entity", key: ASK_RUN_KEY, entityType: "object", entityName: "w_pay", objectName: null });
      expect(env.lastNavigate).toMatchObject({
        tag: "navigate-from-ask",
        route: { view: "objectDetail", name: "w_pay" },
        queryRoute: { view: "queries", sqlText: sql },
      });
    });
  });

  describe("queries/sort", () => {
    it("sets sortCol and defaults to asc on the targeted run", () => {
      const init: QueriesState = { ...initialQueriesState, runs: { top: emptyRun() } };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "sort", key: "top", col: "name" }, (s) => {
        s.runs = { top: emptyRun({ sortCol: "name", sortDir: "asc" }) };
      });
    });

    it("toggles to desc on same column", () => {
      const init: QueriesState = { ...initialQueriesState, runs: { top: emptyRun({ sortCol: "name", sortDir: "asc" }) } };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "sort", key: "top", col: "name" }, (s) => {
        s.runs = { top: emptyRun({ sortCol: "name", sortDir: "desc" }) };
      });
    });

    it("toggles back to asc when already desc", () => {
      const init: QueriesState = { ...initialQueriesState, runs: { top: emptyRun({ sortCol: "name", sortDir: "desc" }) } };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "sort", key: "top", col: "name" }, (s) => {
        s.runs = { top: emptyRun({ sortCol: "name", sortDir: "asc" }) };
      });
    });

    it("resets to asc and clears page on new column", () => {
      const init: QueriesState = { ...initialQueriesState, runs: { top: emptyRun({ sortCol: "name", sortDir: "desc", page: 3 }) } };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "sort", key: "top", col: "cyclomatic" }, (s) => {
        s.runs = { top: emptyRun({ sortCol: "cyclomatic", sortDir: "asc", page: 0 }) };
      });
    });

    it("does nothing when the run does not exist", () => {
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "sort", key: "missing", col: "name" });
    });
  });

  describe("queries/set-page", () => {
    it("sets page number on the targeted run", () => {
      const init: QueriesState = { ...initialQueriesState, runs: { top: emptyRun() } };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "set-page", key: "top", page: 2 }, (s) => {
        s.runs = { top: emptyRun({ page: 2 }) };
      });
    });

    it("does nothing when the run does not exist", () => {
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "set-page", key: "missing", page: 2 });
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
    it("sets generatedSql and creates a loading run under the Ask key", () => {
      const sql = "SELECT name, object FROM procedures ORDER BY cyclomatic DESC LIMIT 20";
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, initialQueriesState);
      ts.send({ tag: "run-sql", sql }, (s) => {
        s.generatedSql = sql;
        s.runs = { [ASK_RUN_KEY]: emptyRun({ sql, loading: true }) };
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
        s.runs = { [ASK_RUN_KEY]: emptyRun({ sql: "SELECT 1", loading: true }) };
        s.recentQueries = ["SELECT 1", "q1", "q2", "q3", "q4"];
      });
    });

    it("does not duplicate the same query at the front", () => {
      const init: QueriesState = { ...initialQueriesState, recentQueries: ["SELECT 1", "q2"] };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "run-sql", sql: "SELECT 1" }, (s) => {
        s.generatedSql = "SELECT 1";
        s.runs = { [ASK_RUN_KEY]: emptyRun({ sql: "SELECT 1", loading: true }) };
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

    it("on failure: sets error on the Ask run and opens query pane", async () => {
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
      ts.receive({ tag: "error", key: ASK_RUN_KEY, error: "Error: syntax error" }, (s) => {
        s.runs[ASK_RUN_KEY]!.results = { error: "Error: syntax error" };
        s.runs[ASK_RUN_KEY]!.loading = false;
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

    it("NL input sets an error result on the Ask run (no LLM at P1)", () => {
      const init: QueriesState = { ...initialQueriesState, askText: "which procedures call f_validate?" };
      const env = makeMockEnv();
      const ts = createTestStore(queriesReducer, env, init);
      ts.send({ tag: "submit-ask" }, (s) => {
        s.runs = { [ASK_RUN_KEY]: emptyRun({ results: { error: expect.stringContaining("SELECT") as unknown as string } }) };
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
        s.runs = { [ASK_RUN_KEY]: emptyRun({ sql, loading: true }) };
        s.recentQueries = [sql];
      });
      expect(env.lastSql).toBe(sql);
    });
  });
});
