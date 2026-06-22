// tests/core/interpreter.test.ts — Reducer-level equivalents of the former PBInterpreter unit tests.
// PBInterpreter was deleted in Plan 101 Stage 5; these tests verify the same behaviour
// via createTestStore + runtimeReducer.

import { describe, it, expect } from "vitest";
import { Effect } from "../../src/core/effect.js";
import { createTestStore } from "../test-store.js";
import {
  runtimeReducer,
  initialRuntimeState,
  type RuntimeEnv,
} from "../../src/features/runtime/reducer.js";
import { readVar, flattenVarEnv } from "../../src/core/cps/var-env.js";
import type { AstData } from "../../src/core/interpreter.js";
import type { BodyStmt, Expr, Located } from "../../src/types/ast.generated.js";
import type { SQLResult } from "../../src/core/dw-queries.js";

// ── Wire-format helpers ────────────────────────────────────────────────────────

function loc(line: number, node: BodyStmt): Located<BodyStmt> {
  return { line, node };
}

function makeAssign(varName: string, value: string): BodyStmt {
  return {
    tag: "BsAssign",
    contents: [
      { segments: [{ name: varName, subscript: null }] },
      { tag: "ExStr", contents: value },
    ],
  };
}

function makeIntAssign(varName: string, value: number): BodyStmt {
  return {
    tag: "BsAssign",
    contents: [
      { segments: [{ name: varName, subscript: null }] },
      { tag: "ExInt", contents: String(value) },
    ],
  };
}

function boolExpr(contents: boolean): Expr {
  return { tag: "ExBool", contents };
}

function makeIf(
  cond: Expr,
  thenStmts: Located<BodyStmt>[],
  elseStmts: Located<BodyStmt>[] | null = null,
): BodyStmt {
  return { tag: "BsIf", contents: { cond, then: thenStmts, elseIfs: [], else: elseStmts } };
}

function makeIfWithElseIf(
  cond: Expr,
  thenStmts: Located<BodyStmt>[],
  elseIfs: { cond: Expr; body: Located<BodyStmt>[] }[],
  elseStmts: Located<BodyStmt>[] | null = null,
): BodyStmt {
  return { tag: "BsIf", contents: { cond, then: thenStmts, elseIfs, else: elseStmts } };
}

function makeCallStmt(calleeSegments: string[], args: string[][] = []): BodyStmt {
  return {
    tag: "BsCall",
    contents: {
      tag: "ExCall",
      callee: { segments: calleeSegments.map((name) => ({ name, subscript: null })) },
      args,
    },
  };
}

function makeReturnStmt(expr: Expr): BodyStmt {
  return { tag: "BsReturn", contents: expr };
}

// ── Test helpers ──────────────────────────────────────────────────────────────

const nullEnv: RuntimeEnv = { executeSql: () => Effect.none() };

function makeAst(overrides?: Partial<AstData>): AstData {
  return { typeBlocks: [], events: [], functions: [], ...overrides };
}

function runEvent(ast: AstData, owner: string, event: string) {
  const ts = createTestStore(runtimeReducer, nullEnv, { ...initialRuntimeState, ast });
  ts.send({ tag: "run-event", owner, event });
  ts.assertDrained();
  return ts.getState();
}

const OPEN_EVENT_BODY = [loc(1, makeAssign("title", "hello"))];
const MINIMAL_AST = makeAst({
  events: [{ name: "open", owner: "w_misth_zpperiod_grid", body: OPEN_EVENT_BODY }],
});

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("PB runtime (formerly PBInterpreter)", () => {
  describe("executeEvent", () => {
    it("executes BsAssign and sets variable in state", () => {
      const state = runEvent(MINIMAL_AST, "w_misth_zpperiod_grid", "open");
      expect(readVar(state.varEnv, "title")).toBe("hello");
    });

    it("does nothing for unknown event", () => {
      const state = runEvent(MINIMAL_AST, "w_misth_zpperiod_grid", "close");
      expect(readVar(state.varEnv, "title")).toBeUndefined();
    });

    it("does nothing for unknown owner", () => {
      const state = runEvent(MINIMAL_AST, "some_other_control", "open");
      expect(readVar(state.varEnv, "title")).toBeUndefined();
    });
  });

  describe("BsIf handling", () => {
    it("executes then branch when condition is literal true", () => {
      const ast = makeAst({
        events: [{
          name: "open", owner: "w_test",
          body: [loc(1, makeIf(boolExpr(true), [loc(2, makeAssign("x", "ran"))]))],
        }],
      });
      expect(readVar(runEvent(ast, "w_test", "open").varEnv, "x")).toBe("ran");
    });

    it("skips then branch when condition is literal false", () => {
      const ast = makeAst({
        events: [{
          name: "open", owner: "w_test",
          body: [loc(1, makeIf(boolExpr(false), [loc(2, makeAssign("x", "should_not_run"))]))],
        }],
      });
      expect(readVar(runEvent(ast, "w_test", "open").varEnv, "x")).toBeUndefined();
    });

    it("executes else branch when condition is false", () => {
      const ast = makeAst({
        events: [{
          name: "open", owner: "w_test",
          body: [loc(1, makeIf(
            boolExpr(false),
            [loc(2, makeAssign("x", "then"))],
            [loc(3, makeAssign("x", "else"))],
          ))],
        }],
      });
      expect(readVar(runEvent(ast, "w_test", "open").varEnv, "x")).toBe("else");
    });

    it("executes matching elseIf branch", () => {
      const ast = makeAst({
        events: [{
          name: "open", owner: "w_test",
          body: [loc(1, makeIfWithElseIf(
            boolExpr(false),
            [loc(2, makeAssign("x", "then"))],
            [{ cond: boolExpr(true), body: [loc(3, makeAssign("x", "elseif"))] }],
          ))],
        }],
      });
      expect(readVar(runEvent(ast, "w_test", "open").varEnv, "x")).toBe("elseif");
    });
  });

  describe("ExInt evaluation", () => {
    it("evaluates integer assignment", () => {
      const ast = makeAst({
        events: [{
          name: "open", owner: "w_test",
          body: [loc(1, makeIntAssign("count", 42))],
        }],
      });
      expect(readVar(runEvent(ast, "w_test", "open").varEnv, "count")).toBe(42);
    });
  });

  describe("ExBool evaluation", () => {
    it("evaluates boolean true assignment", () => {
      const ast = makeAst({
        events: [{
          name: "open", owner: "w_test",
          body: [loc(1, {
            tag: "BsAssign",
            contents: [
              { segments: [{ name: "flag", subscript: null }] },
              { tag: "ExBool", contents: true },
            ],
          })],
        }],
      });
      expect(readVar(runEvent(ast, "w_test", "open").varEnv, "flag")).toBe(true);
    });
  });

  describe("BsReturn", () => {
    it("does not store the return expression to any variable", () => {
      const ast = makeAst({
        events: [{
          name: "open", owner: "w_test",
          body: [
            loc(1, makeIntAssign("result", 0)),
            loc(2, makeReturnStmt({ tag: "ExInt", contents: "99" })),
          ],
        }],
      });
      expect(readVar(runEvent(ast, "w_test", "open").varEnv, "result")).toBe(0);
    });
  });

  describe("BsRaw", () => {
    it("skips raw/SQL statements without error", () => {
      const ast = makeAst({
        events: [{
          name: "open", owner: "w_test",
          body: [
            loc(1, { tag: "BsRaw", contents: "SELECT 1" }),
            loc(2, makeAssign("x", "after_raw")),
          ],
        }],
      });
      expect(readVar(runEvent(ast, "w_test", "open").varEnv, "x")).toBe("after_raw");
    });
  });

  describe("BsCall", () => {
    it("does not crash on unknown function call", () => {
      const ast = makeAst({
        events: [{
          name: "open", owner: "w_test",
          body: [loc(1, makeCallStmt(["SomeFunc"], [["arg1"]]))],
        }],
      });
      expect(runEvent(ast, "w_test", "open").status).toBe("done");
    });
  });

  describe("initial state", () => {
    it("has empty variables and controlValues before any event fires", () => {
      const ts = createTestStore(runtimeReducer, nullEnv, initialRuntimeState);
      ts.send({ tag: "set-ast", ast: MINIMAL_AST });
      ts.assertDrained();
      expect(flattenVarEnv(ts.getState().varEnv)).toEqual({});
      expect(ts.getState().controlValues).toEqual({});
    });
  });

  describe("BsFor", () => {
    it("executes body for each iteration", () => {
      const ast = makeAst({
        events: [{
          name: "open", owner: "w_test",
          body: [
            loc(1, makeIntAssign("sum", 0)),
            loc(2, {
              tag: "BsFor",
              contents: {
                var: { segments: [{ name: "i", subscript: null }] },
                from: { tag: "ExInt", contents: "1" },
                to: { tag: "ExInt", contents: "3" },
                step: null,
                body: [loc(3, {
                  tag: "BsAssign",
                  contents: [
                    { segments: [{ name: "sum", subscript: null }] },
                    { tag: "ExBinOp", lhs: { tag: "ExLvalue", contents: { segments: [{ name: "sum", subscript: null }] } }, op: "BopAdd", rhs: { tag: "ExInt", contents: "1" } },
                  ],
                })],
              },
            }),
          ],
        }],
      });
      expect(readVar(runEvent(ast, "w_test", "open").varEnv, "sum")).toBe(3);
    });

    it("handles step parameter", () => {
      const ast = makeAst({
        events: [{
          name: "open", owner: "w_test",
          body: [
            loc(1, makeIntAssign("count", 0)),
            loc(2, {
              tag: "BsFor",
              contents: {
                var: { segments: [{ name: "i", subscript: null }] },
                from: { tag: "ExInt", contents: "0" },
                to: { tag: "ExInt", contents: "10" },
                step: { tag: "ExInt", contents: "2" },
                body: [loc(3, {
                  tag: "BsAssign",
                  contents: [
                    { segments: [{ name: "count", subscript: null }] },
                    { tag: "ExBinOp", lhs: { tag: "ExLvalue", contents: { segments: [{ name: "count", subscript: null }] } }, op: "BopAdd", rhs: { tag: "ExInt", contents: "1" } },
                  ],
                })],
              },
            }),
          ],
        }],
      });
      expect(readVar(runEvent(ast, "w_test", "open").varEnv, "count")).toBe(6);
    });
  });

  describe("BsDo", () => {
    it("executes body with while condition", () => {
      const ast = makeAst({
        events: [{
          name: "open", owner: "w_test",
          body: [
            loc(1, makeIntAssign("x", 0)),
            loc(2, {
              tag: "BsDo",
              contents: {
                cond: { tag: "DoWhile", contents: { tag: "ExBinOp", lhs: { tag: "ExLvalue", contents: { segments: [{ name: "x", subscript: null }] } }, op: "BopLt", rhs: { tag: "ExInt", contents: "3" } } },
                body: [loc(3, {
                  tag: "BsAssign",
                  contents: [
                    { segments: [{ name: "x", subscript: null }] },
                    { tag: "ExBinOp", lhs: { tag: "ExLvalue", contents: { segments: [{ name: "x", subscript: null }] } }, op: "BopAdd", rhs: { tag: "ExInt", contents: "1" } },
                  ],
                })],
                loop: null,
              },
            }),
          ],
        }],
      });
      expect(readVar(runEvent(ast, "w_test", "open").varEnv, "x")).toBe(3);
    });
  });

  describe("BsChoose", () => {
    it("matches correct case clause", () => {
      const ast = makeAst({
        events: [{
          name: "open", owner: "w_test",
          body: [
            loc(1, makeAssign("mode", "B")),
            loc(2, {
              tag: "BsChoose",
              contents: {
                expr: { tag: "ExLvalue", contents: { segments: [{ name: "mode", subscript: null }] } },
                clauses: [
                  { expr: ['"A"'], body: [loc(3, makeAssign("result", "alpha"))] },
                  { expr: ['"B"'], body: [loc(4, makeAssign("result", "beta"))] },
                  { expr: null, body: [loc(5, makeAssign("result", "other"))] },
                ],
              },
            }),
          ],
        }],
      });
      expect(readVar(runEvent(ast, "w_test", "open").varEnv, "result")).toBe("beta");
    });

    it("falls through to case else when no match", () => {
      const ast = makeAst({
        events: [{
          name: "open", owner: "w_test",
          body: [
            loc(1, makeAssign("mode", "Z")),
            loc(2, {
              tag: "BsChoose",
              contents: {
                expr: { tag: "ExLvalue", contents: { segments: [{ name: "mode", subscript: null }] } },
                clauses: [
                  { expr: ['"A"'], body: [loc(3, makeAssign("result", "alpha"))] },
                  { expr: null, body: [loc(4, makeAssign("result", "default"))] },
                ],
              },
            }),
          ],
        }],
      });
      expect(readVar(runEvent(ast, "w_test", "open").varEnv, "result")).toBe("default");
    });
  });

  describe("BsLocalVar", () => {
    it("initialises variable from init expression", () => {
      const ast = makeAst({
        events: [{
          name: "open", owner: "w_test",
          body: [loc(1, {
            tag: "BsLocalVar",
            name: "greeting",
            mods: [],
            type: { tag: "PtPrimitive", contents: "string" },
            init: { tag: "ExStr", contents: "hello" },
          })],
        }],
      });
      expect(readVar(runEvent(ast, "w_test", "open").varEnv, "greeting")).toBe("hello");
    });
  });

  describe("ExMethodCall retrieve()", () => {
    it("dw_*.retrieve() fires SQL when datawindow name is in DW_QUERIES", () => {
      const MOCK_ROWS = [{ kodperiod: "01", descperiod: "January", orderno: 1 }];
      const sqlResult: SQLResult = { rows: MOCK_ROWS, columns: ["kodperiod", "descperiod", "orderno"], rowcount: 1 };
      const env: RuntimeEnv = { executeSql: () => Effect.send(sqlResult) };
      const ast = makeAst({
        events: [{
          name: "open", owner: "w_test",
          body: [loc(1, {
            tag: "BsCall",
            contents: {
              tag: "ExMethodCall",
              receiver: { tag: "ExLvalue", contents: { segments: [{ name: "dw_misth_zpperiod_list", subscript: null }] } },
              method: "retrieve",
              args: [],
            },
          })],
        }],
      });
      const ts = createTestStore(runtimeReducer, env, { ...initialRuntimeState, ast });
      ts.send({ tag: "run-event", owner: "w_test", event: "open" });
      ts.receive({ tag: "sql-result", dwName: "dw_misth_zpperiod_list", rows: MOCK_ROWS });
      ts.assertDrained();
      expect(ts.getState().controlValues["dw_misth_zpperiod_list"]).toHaveLength(1);
    });

    it("does not set controlValues for non-dw method calls", () => {
      const ast = makeAst({
        events: [{
          name: "open", owner: "w_test",
          body: [loc(1, {
            tag: "BsCall",
            contents: {
              tag: "ExMethodCall",
              receiver: { tag: "ExLvalue", contents: { segments: [{ name: "some_obj", subscript: null }] } },
              method: "retrieve",
              args: [],
            },
          })],
        }],
      });
      expect(runEvent(ast, "w_test", "open").controlValues).toEqual({});
    });
  });

  describe("ExCall dispatch", () => {
    it("dispatches to PB_BUILTINS mid()", () => {
      const ast = makeAst({
        events: [{
          name: "open", owner: "w_test",
          body: [loc(1, {
            tag: "BsAssign",
            contents: [
              { segments: [{ name: "result", subscript: null }] },
              {
                tag: "ExCall",
                callee: { segments: [{ name: "mid", subscript: null }] },
                args: [['"hello"'], ['"2"'], ['"3"']],
              },
            ],
          })],
        }],
      });
      expect(readVar(runEvent(ast, "w_test", "open").varEnv, "result")).toBe("ell");
    });

    it("returns undefined for unknown function", () => {
      const ast = makeAst({
        events: [{
          name: "open", owner: "w_test",
          body: [loc(1, {
            tag: "BsAssign",
            contents: [
              { segments: [{ name: "result", subscript: null }] },
              {
                tag: "ExCall",
                callee: { segments: [{ name: "UnknownFunc", subscript: null }] },
                args: [],
              },
            ],
          })],
        }],
      });
      expect(readVar(runEvent(ast, "w_test", "open").varEnv, "result")).toBeUndefined();
    });
  });
});
