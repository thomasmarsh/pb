// tests/features/runtime-reducer.test.ts — Tests for the runtime reducer.

import { describe, it } from "vitest";
import { Effect } from "../../src/core/effect.js";
import { createTestStore } from "../test-store.js";
import {
  runtimeReducer,
  initialRuntimeState,
  PB_GLOBALS,
  type RuntimeEnv,
} from "../../src/features/runtime/reducer.js";
import type { AstData } from "../../src/core/interpreter.js";

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

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("runtimeReducer", () => {
  describe("set-ast", () => {
    it("stores ast and resets execution state", () => {
      const ast = makeAst();
      const ts = createTestStore(runtimeReducer, nullEnv, {
        ...initialRuntimeState,
        varEnv: { globals: { x: 1 }, instance: {}, locals: [{}] },
        status: "done",
      });
      ts.send({ tag: "set-ast", ast }, (s) => {
        s.ast = ast;
        s.varEnv = { globals: {}, instance: {}, locals: [{}] };
        s.controlValues = {};
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
        s.varEnv.globals = { ...PB_GLOBALS };
        s.varEnv.locals[0]!.greeting = "hello";
      });
      ts.assertDrained();
    });

    it("transitions to done with empty body", () => {
      const ast = makeAst({ events: [{ name: "open", owner: "w_test", body: [] }] });
      const ts = createTestStore(runtimeReducer, nullEnv, { ...initialRuntimeState, ast });
      ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (s) => {
        s.status = "done";
        s.varEnv.globals = { ...PB_GLOBALS };
      });
      ts.assertDrained();
    });

    it("is a no-op when ast is null", () => {
      const ts = createTestStore(runtimeReducer, nullEnv, initialRuntimeState);
      ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (_s) => {});
      ts.assertDrained();
    });
  });

  describe("run-event / globals seeding", () => {
    it("seeds PB_GLOBALS into variables before executing body", () => {
      const ast = makeAst({ events: [{ name: "open", owner: "w_test", body: [] }] });
      const ts = createTestStore(runtimeReducer, nullEnv, { ...initialRuntimeState, ast });
      ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (s) => {
        s.status = "done";
        s.varEnv.globals = { ...PB_GLOBALS };
      });
      ts.assertDrained();
    });

    it("does not overwrite variables already set before run-event", () => {
      const ast = makeAst({ events: [{ name: "open", owner: "w_test", body: [] }] });
      const ts = createTestStore(runtimeReducer, nullEnv, {
        ...initialRuntimeState,
        ast,
        varEnv: { globals: { gs_kodxrisi: "9999" } as Record<string, unknown>, instance: {}, locals: [{}] },
      });
      ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (s) => {
        s.status = "done";
        s.varEnv.globals = { gs_kodxrisi: "9999", gs_app_name: "OpenPay", gs_username: "admin" };
      });
      ts.assertDrained();
    });
  });

  describe("run-event / BsIf inline expansion", () => {
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
        s.varEnv.globals = { ...PB_GLOBALS };
        s.varEnv.instance = { ib_retrieve: false };
      });
      ts.assertDrained();
    });
  });

  describe("run-event / frame isolation", () => {
    it("callee locals do not clobber caller's variable of the same name", () => {
      // Caller event 'open': sets i = 1, calls helper().
      // helper declares local integer i = 99.
      // Without frame isolation, i would be 99 after the call returns.
      const lvalueI = { segments: [{ name: "i", subscript: null }] };

      const helperBody = [
        {
          line: 1,
          node: {
            tag: "BsLocalVar" as const,
            mods: [],
            type: { tag: "PtPrimitive" as const, contents: "integer" },
            name: "i",
            init: { tag: "ExInt" as const, contents: "99" },
          },
        },
      ];

      const ast = makeAst({
        functions: [{ name: "helper", owner: "w_test", body: helperBody }],
        events: [
          {
            name: "open",
            owner: "w_test",
            body: [
              {
                line: 1,
                node: {
                  tag: "BsAssign" as const,
                  contents: [lvalueI, { tag: "ExInt" as const, contents: "1" }],
                },
              },
              {
                line: 2,
                node: {
                  tag: "BsCall" as const,
                  contents: {
                    tag: "ExCall" as const,
                    callee: { segments: [{ name: "helper", subscript: null }] },
                    args: [],
                  },
                },
              },
            ],
          },
        ],
      });

      const ts = createTestStore(runtimeReducer, nullEnv, initialRuntimeState);
      ts.send({ tag: "set-ast", ast });
      ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (s) => {
        s.status = "done";
        s.varEnv.globals = { ...PB_GLOBALS };
        s.varEnv.locals[0]!.i = 1;   // caller's i must be 1, not 99
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
