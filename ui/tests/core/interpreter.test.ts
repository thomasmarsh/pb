// tests/core/interpreter.test.ts — Unit tests for PBInterpreter.

import { describe, it, expect } from "vitest";
import { PBInterpreter } from "../../src/core/interpreter.js";
import type { BodyStmt, Expr, Located } from "../../src/types/ast.generated.js";

// Wire-format helpers matching the generated AST types.

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

function makeIf(cond: Expr, thenStmts: Located<BodyStmt>[], elseStmts: Located<BodyStmt>[] | null = null): BodyStmt {
  return {
    tag: "BsIf",
    contents: { cond, then: thenStmts, elseIfs: [], else: elseStmts },
  };
}

function makeIfWithElseIf(
  cond: Expr,
  thenStmts: Located<BodyStmt>[],
  elseIfs: { cond: Expr; body: Located<BodyStmt>[] }[],
  elseStmts: Located<BodyStmt>[] | null = null,
): BodyStmt {
  return {
    tag: "BsIf",
    contents: { cond, then: thenStmts, elseIfs, else: elseStmts },
  };
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

const OPEN_EVENT_BODY = [loc(1, makeAssign("title", "hello"))];

const MINIMAL_AST = {
  typeBlocks: [],
  events: [
    { name: "open", owner: "w_misth_zpperiod_grid", body: OPEN_EVENT_BODY },
  ],
};

describe("PBInterpreter", () => {
  describe("executeEvent", () => {
    it("executes BsAssign and sets variable in state", async () => {
      const interp = new PBInterpreter();
      interp.setAst(MINIMAL_AST);
      await interp.executeEvent("w_misth_zpperiod_grid", "open");
      const state = interp.getState();
      expect(state.variables["title"]).toBe("hello");
    });

    it("does nothing for unknown event", async () => {
      const interp = new PBInterpreter();
      interp.setAst(MINIMAL_AST);
      await interp.executeEvent("w_misth_zpperiod_grid", "close");
      const state = interp.getState();
      expect(Object.keys(state.variables)).toHaveLength(0);
    });

    it("does nothing for unknown owner", async () => {
      const interp = new PBInterpreter();
      interp.setAst(MINIMAL_AST);
      await interp.executeEvent("some_other_control", "open");
      const state = interp.getState();
      expect(Object.keys(state.variables)).toHaveLength(0);
    });
  });

  describe("BsIf handling", () => {
    it("executes then branch when condition is literal true", async () => {
      const interp = new PBInterpreter();
      interp.setAst({
        typeBlocks: [],
        events: [{
          name: "open", owner: "w_test",
          body: [loc(1, makeIf(boolExpr(true), [loc(2, makeAssign("x", "ran"))]))],
        }],
      });
      await interp.executeEvent("w_test", "open");
      expect(interp.getState().variables["x"]).toBe("ran");
    });

    it("skips then branch when condition is literal false", async () => {
      const interp = new PBInterpreter();
      interp.setAst({
        typeBlocks: [],
        events: [{
          name: "open", owner: "w_test",
          body: [loc(1, makeIf(boolExpr(false), [loc(2, makeAssign("x", "should_not_run"))]))],
        }],
      });
      await interp.executeEvent("w_test", "open");
      expect(interp.getState().variables["x"]).toBeUndefined();
    });

    it("executes else branch when condition is false", async () => {
      const interp = new PBInterpreter();
      interp.setAst({
        typeBlocks: [],
        events: [{
          name: "open", owner: "w_test",
          body: [loc(1, makeIf(
            boolExpr(false),
            [loc(2, makeAssign("x", "then"))],
            [loc(3, makeAssign("x", "else"))],
          ))],
        }],
      });
      await interp.executeEvent("w_test", "open");
      expect(interp.getState().variables["x"]).toBe("else");
    });

    it("executes matching elseIf branch", async () => {
      const interp = new PBInterpreter();
      interp.setAst({
        typeBlocks: [],
        events: [{
          name: "open", owner: "w_test",
          body: [loc(1, makeIfWithElseIf(
            boolExpr(false),
            [loc(2, makeAssign("x", "then"))],
            [{ cond: boolExpr(true), body: [loc(3, makeAssign("x", "elseif"))] }],
          ))],
        }],
      });
      await interp.executeEvent("w_test", "open");
      expect(interp.getState().variables["x"]).toBe("elseif");
    });
  });

  describe("ExInt evaluation", () => {
    it("evaluates integer assignment", async () => {
      const interp = new PBInterpreter();
      interp.setAst({
        typeBlocks: [],
        events: [{
          name: "open", owner: "w_test",
          body: [loc(1, makeIntAssign("count", 42))],
        }],
      });
      await interp.executeEvent("w_test", "open");
      expect(interp.getState().variables["count"]).toBe(42);
    });
  });

  describe("ExBool evaluation", () => {
    it("evaluates boolean true assignment", async () => {
      const interp = new PBInterpreter();
      interp.setAst({
        typeBlocks: [],
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
      await interp.executeEvent("w_test", "open");
      expect(interp.getState().variables["flag"]).toBe(true);
    });
  });

  describe("BsReturn", () => {
    it("evaluates return expression", async () => {
      const interp = new PBInterpreter();
      interp.setAst({
        typeBlocks: [],
        events: [{
          name: "open", owner: "w_test",
          body: [
            loc(1, makeIntAssign("result", 0)),
            loc(2, makeReturnStmt({ tag: "ExInt", contents: "99" })),
          ],
        }],
      });
      await interp.executeEvent("w_test", "open");
      expect(interp.getState().variables["result"]).toBe(0);
    });
  });

  describe("BsRaw", () => {
    it("skips raw/SQL statements without error", async () => {
      const interp = new PBInterpreter();
      interp.setAst({
        typeBlocks: [],
        events: [{
          name: "open", owner: "w_test",
          body: [
            loc(1, { tag: "BsRaw", contents: "SELECT 1" }),
            loc(2, makeAssign("x", "after_raw")),
          ],
        }],
      });
      await interp.executeEvent("w_test", "open");
      expect(interp.getState().variables["x"]).toBe("after_raw");
    });
  });

  describe("BsCall", () => {
    it("does not crash on unknown function call", async () => {
      const interp = new PBInterpreter();
      interp.setAst({
        typeBlocks: [],
        events: [{
          name: "open", owner: "w_test",
          body: [loc(1, makeCallStmt(["SomeFunc"], [["arg1"]]))],
        }],
      });
      await interp.executeEvent("w_test", "open");
    });
  });

  describe("getState", () => {
    it("returns empty state before any event fires", () => {
      const interp = new PBInterpreter();
      interp.setAst(MINIMAL_AST);
      const state = interp.getState();
      expect(state.variables).toEqual({});
      expect(state.controlValues).toEqual({});
    });
  });
});
