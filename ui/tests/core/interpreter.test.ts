// tests/core/interpreter.test.ts — Unit tests for PBInterpreter.

import { describe, it, expect } from "vitest";
import { PBInterpreter } from "../../src/core/interpreter.js";

// Minimal BsAssign AST node: `title = "hello"`
function makeAssignNode(varName: string, value: string) {
  return {
    line: 1,
    node: {
      tag: "BsAssign",
      lhs: { segments: [{ name: varName, subscript: null }] },
      rhs: { tag: "ExStr", contents: value },
    },
  };
}

// Minimal BsIf AST node with a literal-true condition
function makeIfNode(thenStmts: unknown[]) {
  return {
    line: 2,
    node: {
      tag: "BsIf",
      cond: { tag: "ExLit", contents: { tag: "LitBool", contents: true } },
      then: thenStmts,
      elseIfs: [],
      else: null,
    },
  };
}

const OPEN_EVENT_BODY = [makeAssignNode("title", "hello")];

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
        events: [
          {
            name: "open",
            owner: "w_test",
            body: [makeIfNode([makeAssignNode("x", "ran")])],
          },
        ],
      });
      await interp.executeEvent("w_test", "open");
      expect(interp.getState().variables["x"]).toBe("ran");
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
