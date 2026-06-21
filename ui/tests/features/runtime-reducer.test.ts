// tests/features/runtime-reducer.test.ts — Tests for the runtime reducer.

import { describe, it } from "vitest";
import { Effect } from "../../src/core/effect.js";
import { createTestStore } from "../test-store.js";
import {
  runtimeReducer,
  initialRuntimeState,
  PB_GLOBALS,
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
        s.variables = { ...PB_GLOBALS, greeting: "hello" };
      });
      ts.assertDrained();
    });

    it("transitions to done with empty body", () => {
      const ast = makeAst({ events: [{ name: "open", owner: "w_test", body: [] }] });
      const ts = createTestStore(runtimeReducer, nullEnv, { ...initialRuntimeState, ast });
      ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (s) => {
        s.status = "done";
        s.variables = { ...PB_GLOBALS };
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
        s.variables = { ...PB_GLOBALS };
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
        s.variables = { ...PB_GLOBALS };
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
        s.variables = { ...PB_GLOBALS };
      });

      ts.receive(
        { tag: "sql-result", dwName: "dw_misth_zpperiod_list", rows: ROWS },
        (s: RuntimeState) => {
          s.controlValues = { dw_misth_zpperiod_list: ROWS };
          s.variables = { ...PB_GLOBALS, x: 42 };
          s.status = "done";
          s.continuation = null;
        },
      );

      ts.assertDrained();
    });
  });

  describe("run-event / globals seeding", () => {
    it("seeds PB_GLOBALS into variables before executing body", () => {
      const ast = makeAst({ events: [{ name: "open", owner: "w_test", body: [] }] });
      const ts = createTestStore(runtimeReducer, nullEnv, { ...initialRuntimeState, ast });
      ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (s) => {
        s.status = "done";
        s.variables = { ...PB_GLOBALS };
      });
      ts.assertDrained();
    });

    it("does not overwrite variables already set before run-event", () => {
      const ast = makeAst({ events: [{ name: "open", owner: "w_test", body: [] }] });
      const ts = createTestStore(runtimeReducer, nullEnv, {
        ...initialRuntimeState,
        ast,
        variables: { gs_kodxrisi: "9999" } as Record<string, unknown>,
      });
      ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (s) => {
        s.status = "done";
        s.variables = { gs_kodxrisi: "9999", gs_app_name: "OpenPay", gs_username: "admin" };
      });
      ts.assertDrained();
    });
  });

  describe("run-event / fn_retrievechild intercept", () => {
    it("fires executeSql for fn_retrievechild(adw, 'kodperiod', arg)", () => {
      const MOCK_ROWS = [{ kodperiod: "0001", descperiod: "Year 2001" }];
      const sqlResult: SQLResult = { rows: MOCK_ROWS, columns: ["kodperiod", "descperiod"], rowcount: 1 };

      const env: RuntimeEnv = {
        executeSql: (_sql, _params) => Effect.send(sqlResult),
      };

      const ast = makeAst({
        events: [
          {
            name: "open",
            owner: "w_misth_final_search",
            body: [
              {
                line: 1,
                node: {
                  tag: "BsCall",
                  contents: {
                    tag: "ExCall",
                    callee: { segments: [{ name: "fn_retrievechild", subscript: null }] },
                    args: [["dw"], ['"kodperiod"'], ["gs_kodxrisi"]],
                  },
                },
              },
            ],
          },
        ],
      });

      const ts = createTestStore(runtimeReducer, env, { ...initialRuntimeState, ast });

      ts.send({ tag: "run-event", owner: "w_misth_final_search", event: "open" }, (s) => {
        s.status = "awaiting-sql";
        s.continuation = [];
        s.variables = { ...PB_GLOBALS };
      });

      ts.receive(
        { tag: "sql-result", dwName: "child_kodperiod", rows: MOCK_ROWS },
        (s: RuntimeState) => {
          s.controlValues = { child_kodperiod: MOCK_ROWS };
          s.status = "done";
          s.continuation = null;
        },
      );

      ts.assertDrained();
    });
  });

  describe("run-event / user-defined function dispatch", () => {
    it("inline-expands a function from ast.functions by name", () => {
      const ROWS = [{ id: 1 }];
      const sqlResult: SQLResult = { rows: ROWS, columns: ["id"], rowcount: 1 };
      const env: RuntimeEnv = { executeSql: () => Effect.send(sqlResult) };

      // fn_helper is defined in ast.functions; its body calls dw_misth_zpperiod_list.retrieve
      const fnBody = [
        {
          line: 10,
          node: {
            tag: "BsCall" as const,
            contents: {
              tag: "ExCall" as const,
              callee: {
                segments: [
                  { name: "dw_misth_zpperiod_list", subscript: null },
                  { name: "retrieve", subscript: null },
                ],
              },
              args: [["gs_kodxrisi"]],
            },
          },
        },
      ];

      const ast = makeAst({
        functions: [{ name: "fn_helper", owner: "w_test", body: fnBody }],
        events: [
          {
            name: "open",
            owner: "w_test",
            body: [
              {
                line: 1,
                node: {
                  tag: "BsCall" as const,
                  contents: {
                    tag: "ExCall" as const,
                    callee: { segments: [{ name: "fn_helper", subscript: null }] },
                    args: [],
                  },
                },
              },
            ],
          },
        ],
      });

      const ts = createTestStore(runtimeReducer, env, { ...initialRuntimeState, ast });

      ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (s) => {
        s.status = "awaiting-sql";
        s.continuation = [];
        s.variables = { ...PB_GLOBALS };
      });

      ts.receive(
        { tag: "sql-result", dwName: "dw_misth_zpperiod_list", rows: ROWS },
        (s: RuntimeState) => {
          s.controlValues = { dw_misth_zpperiod_list: ROWS };
          s.status = "done";
          s.continuation = null;
        },
      );

      ts.assertDrained();
    });
  });

  describe("run-event / BsIf inline expansion", () => {
    it("executes then-branch when condition is true", () => {
      const ROWS = [{ id: 1 }];
      const sqlResult: SQLResult = { rows: ROWS, columns: ["id"], rowcount: 1 };
      const env: RuntimeEnv = { executeSql: () => Effect.send(sqlResult) };

      // open event: if ib_retrieve then dw_misth_zpperiod_list.retrieve(gs_kodxrisi)
      const ast = makeAst({
        typeBlocks: [
          {
            decl: { ancestor: "window", name: "w_test", within: null },
            body: [
              {
                line: 1,
                node: {
                  tag: "BsLocalVar" as const,
                  name: "ib_retrieve",
                  mods: [],
                  type: { tag: "PtPrimitive" as const, contents: "boolean" },
                  init: { tag: "ExBool" as const, contents: true },
                },
              },
            ],
          },
        ],
        events: [
          {
            name: "open",
            owner: "w_test",
            body: [
              {
                line: 2,
                node: {
                  tag: "BsIf" as const,
                  contents: {
                    cond: { tag: "ExLvalue" as const, contents: { segments: [{ name: "ib_retrieve", subscript: null }] } },
                    then: [
                      {
                        line: 3,
                        node: {
                          tag: "BsCall" as const,
                          contents: {
                            tag: "ExCall" as const,
                            callee: { segments: [{ name: "dw_misth_zpperiod_list", subscript: null }, { name: "retrieve", subscript: null }] },
                            args: [["gs_kodxrisi"]],
                          },
                        },
                      },
                    ],
                    elseIfs: [],
                    else: null,
                  },
                },
              },
            ],
          },
        ],
      });

      const ts = createTestStore(runtimeReducer, env, { ...initialRuntimeState, ast });
      ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (s) => {
        s.status = "awaiting-sql";
        s.continuation = [];
        s.variables = { ...PB_GLOBALS, ib_retrieve: true };
      });
      ts.receive(
        { tag: "sql-result", dwName: "dw_misth_zpperiod_list", rows: ROWS },
        (s: RuntimeState) => {
          s.controlValues = { dw_misth_zpperiod_list: ROWS };
          s.status = "done";
          s.continuation = null;
        },
      );
      ts.assertDrained();
    });

    it("skips then-branch when condition is false", () => {
      const ast = makeAst({
        typeBlocks: [
          {
            decl: { ancestor: "window", name: "w_test", within: null },
            body: [
              {
                line: 1,
                node: {
                  tag: "BsLocalVar" as const,
                  name: "ib_retrieve",
                  mods: [],
                  type: { tag: "PtPrimitive" as const, contents: "boolean" },
                  init: { tag: "ExBool" as const, contents: false },
                },
              },
            ],
          },
        ],
        events: [
          {
            name: "open",
            owner: "w_test",
            body: [
              {
                line: 2,
                node: {
                  tag: "BsIf" as const,
                  contents: {
                    cond: { tag: "ExLvalue" as const, contents: { segments: [{ name: "ib_retrieve", subscript: null }] } },
                    then: [
                      {
                        line: 3,
                        node: {
                          tag: "BsCall" as const,
                          contents: {
                            tag: "ExCall" as const,
                            callee: { segments: [{ name: "dw_misth_zpperiod_list", subscript: null }, { name: "retrieve", subscript: null }] },
                            args: [["gs_kodxrisi"]],
                          },
                        },
                      },
                    ],
                    elseIfs: [],
                    else: null,
                  },
                },
              },
            ],
          },
        ],
      });

      const ts = createTestStore(runtimeReducer, nullEnv, { ...initialRuntimeState, ast });
      ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (s) => {
        s.status = "done";
        s.variables = { ...PB_GLOBALS, ib_retrieve: false };
      });
      ts.assertDrained();
    });
  });

  describe("run-event / w_list ancestor chain", () => {
    it("fires dw.retrieve() through call super::open → BsIf(ib_retrieve) → TriggerEvent(ie_retrieve) → of_retrieve → dw.retrieve()", () => {
      const ROWS = [{ kodkrat: "A01", desckrat: "Allowance" }];
      const sqlResult: SQLResult = { rows: ROWS, columns: ["kodkrat", "desckrat"], rowcount: ROWS.length };
      const env: RuntimeEnv = { executeSql: () => Effect.send(sqlResult) };

      // Minimal w_list ancestor open event: BsIf(ib_retrieve) { TriggerEvent("ie_retrieve") }
      const ancestorOpenBody = [
        {
          line: 10,
          node: {
            tag: "BsIf" as const,
            contents: {
              cond: { tag: "ExLvalue" as const, contents: { segments: [{ name: "ib_retrieve", subscript: null }] } },
              then: [
                {
                  line: 11,
                  node: {
                    tag: "BsCall" as const,
                    contents: {
                      tag: "ExCall" as const,
                      callee: { segments: [{ name: "TriggerEvent", subscript: null }] },
                      args: [['"ie_retrieve"']],
                    },
                  },
                },
              ],
              elseIfs: [],
              else: null,
            },
          },
        },
      ];

      // ie_retrieve body: of_retrieve(dw)
      const ieRetrieveBody = [
        {
          line: 20,
          node: {
            tag: "BsCall" as const,
            contents: {
              tag: "ExCall" as const,
              callee: { segments: [{ name: "of_retrieve", subscript: null }] },
              args: [["dw"]],
            },
          },
        },
      ];

      // of_retrieve body: dw.retrieve()
      const ofRetrieveBody = [
        {
          line: 30,
          node: {
            tag: "BsCall" as const,
            contents: {
              tag: "ExCall" as const,
              callee: { segments: [{ name: "dw", subscript: null }, { name: "retrieve", subscript: null }] },
              args: [],
            },
          },
        },
      ];

      const ast: AstData = {
        typeBlocks: [
          {
            decl: { ancestor: "w_list", name: "w_misth_zpkrat_list", within: null },
            body: [
              {
                line: 1,
                node: {
                  tag: "BsLocalVar" as const,
                  name: "ib_retrieve",
                  mods: [],
                  type: { tag: "PtPrimitive" as const, contents: "boolean" },
                  init: { tag: "ExBool" as const, contents: true },
                },
              },
            ],
          },
          {
            decl: { ancestor: "w_list`dw", name: "dw", within: "w_misth_zpkrat_list" },
            body: [
              {
                line: 2,
                node: {
                  tag: "BsLocalVar" as const,
                  name: "dataobject",
                  mods: [],
                  type: { tag: "PtPrimitive" as const, contents: "string" },
                  init: { tag: "ExStr" as const, contents: "dw_misth_zpkrat_list" },
                },
              },
            ],
          },
        ],
        events: [
          {
            name: "open",
            owner: "w_misth_zpkrat_list",
            body: [
              {
                line: 5,
                node: {
                  tag: "BsRaw" as const,
                  contents: "call super::open",
                },
              },
            ],
          },
        ],
        ancestorName: "w_list",
        ancestorEvents: [
          { name: "open", owner: "w_list", body: ancestorOpenBody },
          { name: "ie_retrieve", owner: "w_list", body: ieRetrieveBody },
        ],
        ancestorFunctions: [
          { name: "of_retrieve", owner: "w_list", body: ofRetrieveBody },
        ],
      };

      const ts = createTestStore(runtimeReducer, env, { ...initialRuntimeState, ast });

      ts.send({ tag: "run-event", owner: "w_misth_zpkrat_list", event: "open" }, (s) => {
        s.status = "awaiting-sql";
        s.continuation = [];
        s.variables = { ...PB_GLOBALS, ib_retrieve: true };
      });

      ts.receive(
        { tag: "sql-result", dwName: "dw", rows: ROWS },
        (s: RuntimeState) => {
          s.controlValues = { dw: ROWS };
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
