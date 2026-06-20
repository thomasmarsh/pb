// tests/features/runtime-reducer.test.ts — Tests for the runtime reducer.

import { describe, it } from "vitest";
import { Effect } from "../../src/core/effect.js";
import { createTestStore } from "../test-store.js";
import {
  runtimeReducer,
  initialRuntimeState,
  type RuntimeEnv,
  type RuntimeState,
} from "../../src/features/runtime/reducer.js";
import type { AstData } from "../../src/core/interpreter.js";
import type { SQLResult } from "../../src/core/dw-queries.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

const nullEnv: RuntimeEnv = {
  executeSql: () => Effect.none(),
};

function makeAst(overrides?: Partial<AstData>): AstData {
  return {
    typeBlocks: [],
    events: [],
    functions: [],
    ...overrides,
  };
}

// ExMethodCall variant: complex receiver expression (kept for completeness)
function makeRetrieveEventMethodCall(owner: string, dwName: string): AstData {
  return makeAst({
    events: [
      {
        name: "open",
        owner,
        body: [
          {
            line: 1,
            node: {
              tag: "BsCall",
              contents: {
                tag: "ExMethodCall",
                receiver: { tag: "ExLvalue", contents: { segments: [{ name: dwName, subscript: null }] } },
                method: "retrieve",
                args: [["\"01\""]],
              },
            },
          },
        ],
      },
    ],
  });
}

// ExCall variant: 2-segment callee — the actual corpus pattern produced by the PB parser
function makeRetrieveEventExCall(owner: string, dwName: string): AstData {
  return makeAst({
    events: [
      {
        name: "open",
        owner,
        body: [
          {
            line: 1,
            node: {
              tag: "BsCall",
              contents: {
                tag: "ExCall",
                callee: { segments: [{ name: dwName, subscript: null }, { name: "retrieve", subscript: null }] },
                args: [["gs_kodxrisi"]],
              },
            },
          },
        ],
      },
    ],
  });
}

// Keep old name as alias for the ExMethodCall variant (existing tests reference it)
const makeRetrieveEvent = makeRetrieveEventMethodCall;

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("runtimeReducer", () => {
  describe("set-ast", () => {
    it("stores ast and resets execution state", () => {
      const ast = makeAst();
      const ts = createTestStore(runtimeReducer, nullEnv, {
        ...initialRuntimeState,
        variables: { x: 1 },
        status: "done",
      });
      ts.send({ tag: "set-ast", ast }, (s) => {
        s.ast = ast;
        s.variables = {};
        s.controlValues = {};
        s.continuation = null;
        s.status = "idle";
        s.error = null;
      });
      ts.assertDrained();
    });
  });

  describe("run-event / no retrieve", () => {
    it("executes synchronous assignment and transitions to done", () => {
      const ast = makeAst({
        events: [
          {
            name: "open",
            owner: "w_test",
            body: [
              {
                line: 1,
                node: {
                  tag: "BsAssign",
                  contents: [
                    { segments: [{ name: "greeting", subscript: null }] },
                    { tag: "ExStr", contents: "hello" },
                  ],
                },
              },
            ],
          },
        ],
      });
      const ts = createTestStore(runtimeReducer, nullEnv, { ...initialRuntimeState, ast });
      ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (s) => {
        s.status = "done";
        s.variables = { greeting: "hello" };
      });
      ts.assertDrained();
    });

    it("transitions to done with empty body", () => {
      const ast = makeAst({ events: [{ name: "open", owner: "w_test", body: [] }] });
      const ts = createTestStore(runtimeReducer, nullEnv, { ...initialRuntimeState, ast });
      ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (s) => {
        s.status = "done";
      });
      ts.assertDrained();
    });

    it("is a no-op when ast is null", () => {
      const ts = createTestStore(runtimeReducer, nullEnv, initialRuntimeState);
      ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (_s) => {});
      ts.assertDrained();
    });
  });

  describe("run-event / retrieve suspension", () => {
    it("fires executeSql effect for ExCall pattern (corpus pattern: dw_name.retrieve)", () => {
      const MOCK_ROWS = [{ kodperiod: "01", descperiod: "January", orderno: 1 }];
      const sqlResult: SQLResult = { rows: MOCK_ROWS, columns: ["kodperiod", "descperiod", "orderno"], rowcount: 1 };

      const env: RuntimeEnv = {
        executeSql: (_sql, _params) => Effect.send(sqlResult),
      };

      const ast = makeRetrieveEventExCall("w_krat_total_search", "dw_period");
      const ts = createTestStore(runtimeReducer, env, { ...initialRuntimeState, ast });

      ts.send({ tag: "run-event", owner: "w_krat_total_search", event: "open" }, (s) => {
        s.status = "awaiting-sql";
        s.continuation = [];
      });

      ts.receive(
        { tag: "sql-result", dwName: "dw_period", rows: MOCK_ROWS },
        (s: RuntimeState) => {
          s.controlValues = { dw_period: MOCK_ROWS };
          s.status = "done";
          s.continuation = null;
        },
      );

      ts.assertDrained();
    });

    it("fires executeSql effect when retrieve() is encountered (ExMethodCall variant)", () => {
      const MOCK_ROWS = [{ kodperiod: "01", descperiod: "January", orderno: 1 }];
      const sqlResult: SQLResult = { rows: MOCK_ROWS, columns: ["kodperiod", "descperiod", "orderno"], rowcount: 1 };

      const env: RuntimeEnv = {
        executeSql: (_sql, _params) => Effect.send(sqlResult),
      };

      const ast = makeRetrieveEvent("w_misth_zpperiod_grid", "dw_misth_zpperiod_list");
      const ts = createTestStore(runtimeReducer, env, { ...initialRuntimeState, ast });

      ts.send({ tag: "run-event", owner: "w_misth_zpperiod_grid", event: "open" }, (s) => {
        s.status = "awaiting-sql";
        s.continuation = [];
      });

      ts.receive(
        { tag: "sql-result", dwName: "dw_misth_zpperiod_list", rows: MOCK_ROWS },
        (s: RuntimeState) => {
          s.controlValues = { dw_misth_zpperiod_list: MOCK_ROWS };
          s.status = "done";
          s.continuation = null;
        },
      );

      ts.assertDrained();
    });

    it("resumes continuation after sql-result", () => {
      const ROWS = [{ id: 1 }];
      const sqlResult: SQLResult = { rows: ROWS, columns: ["id"], rowcount: 1 };

      const env: RuntimeEnv = {
        executeSql: () => Effect.send(sqlResult),
      };

      // Event: dw_misth_zpperiod_list.retrieve("01"), then x = 1
      const ast = makeAst({
        events: [
          {
            name: "open",
            owner: "w_test",
            body: [
              {
                line: 1,
                node: {
                  tag: "BsCall",
                  contents: {
                    tag: "ExMethodCall",
                    receiver: { tag: "ExLvalue", contents: { segments: [{ name: "dw_misth_zpperiod_list", subscript: null }] } },
                    method: "retrieve",
                    args: [["\"01\""]],
                  },
                },
              },
              {
                line: 2,
                node: {
                  tag: "BsAssign",
                  contents: [
                    { segments: [{ name: "x", subscript: null }] },
                    { tag: "ExInt", contents: "42" },
                  ],
                },
              },
            ],
          },
        ],
      });

      const ts = createTestStore(runtimeReducer, env, { ...initialRuntimeState, ast });

      ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (s) => {
        s.status = "awaiting-sql";
        s.continuation = [ast.events[0]!.body[1]!]; // the x=42 stmt
      });

      ts.receive(
        { tag: "sql-result", dwName: "dw_misth_zpperiod_list", rows: ROWS },
        (s: RuntimeState) => {
          s.controlValues = { dw_misth_zpperiod_list: ROWS };
          s.variables = { x: 42 };
          s.status = "done";
          s.continuation = null;
        },
      );

      ts.assertDrained();
    });
  });

  describe("sql-result / no continuation", () => {
    it("stores rows and marks done", () => {
      const rows = [{ a: 1 }];
      const ts = createTestStore(runtimeReducer, nullEnv, {
        ...initialRuntimeState,
        status: "awaiting-sql",
        continuation: [],
      });
      ts.send({ tag: "sql-result", dwName: "dw_foo", rows }, (s) => {
        s.controlValues = { dw_foo: rows };
        s.status = "done";
        s.continuation = null;
      });
      ts.assertDrained();
    });
  });

  describe("error", () => {
    it("records error message and status", () => {
      const ts = createTestStore(runtimeReducer, nullEnv, initialRuntimeState);
      ts.send({ tag: "error", message: "boom" }, (s) => {
        s.status = "error";
        s.error = "boom";
      });
      ts.assertDrained();
    });
  });
});
