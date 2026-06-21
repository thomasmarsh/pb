// tests/core/cps/compile.test.ts — Tests for the CPS compiler.

import { describe, it, expect } from "vitest";
import { compileFunction } from "../../../src/core/cps/compile.js";
import type { Located } from "../../../src/types/ast.generated.js";
import type { BodyStmt } from "../../../src/types/ast.generated.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function assign(varName: string, intVal: string, line = 1): Located<BodyStmt> {
  return {
    line,
    node: {
      tag: "BsAssign",
      contents: [
        { segments: [{ name: varName, subscript: null }] },
        { tag: "ExInt", contents: intVal },
      ],
    } as unknown as BodyStmt,
  };
}

function bsCall(calleeSegments: string[], argTokens: string[][] = [], line = 1): Located<BodyStmt> {
  return {
    line,
    node: {
      tag: "BsCall",
      contents: {
        tag: "ExCall",
        callee: { segments: calleeSegments.map((name) => ({ name, subscript: null })) },
        args: argTokens,
      },
    } as unknown as BodyStmt,
  };
}

function bsIf(
  condTag: string,
  condVal: unknown,
  thenStmts: Located<BodyStmt>[],
  elseStmts?: Located<BodyStmt>[],
  line = 10,
): Located<BodyStmt> {
  return {
    line,
    node: {
      tag: "BsIf",
      contents: {
        cond: { tag: condTag, contents: condVal },
        then: thenStmts,
        elseIfs: [],
        else: elseStmts ?? null,
      },
    } as unknown as BodyStmt,
  };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("compileFunction", () => {
  it("compiles empty body to single return", () => {
    const graph = compileFunction([]);
    expect(graph.nodes).toHaveLength(1);
    expect(graph.nodes[0]!.kind).toBe("return");
    expect(graph.entry).toBe(0);
  });

  it("compiles BsAssign to assign + return", () => {
    const graph = compileFunction([assign("x", "42")]);
    // return(0) + assign(1) = 2 nodes; entry points to assign
    expect(graph.nodes).toHaveLength(2);
    expect(graph.nodes[0]!.kind).toBe("return");
    expect(graph.nodes[1]!.kind).toBe("assign");
    expect(graph.entry).toBe(1);
    if (graph.nodes[1]!.kind === "assign") {
      expect(graph.nodes[1]!.var).toBe("x");
      expect(graph.nodes[1]!.next).toBe(0); // falls through to return
    }
  });

  it("compiles BsCall to call + return", () => {
    const graph = compileFunction([bsCall(["trn"], [["529"]])]);
    expect(graph.nodes).toHaveLength(2);
    expect(graph.nodes[0]!.kind).toBe("return");
    expect(graph.nodes[1]!.kind).toBe("call");
    expect(graph.entry).toBe(1);
    if (graph.nodes[1]!.kind === "call") {
      expect(graph.nodes[1]!.callee).toBe("trn");
    }
  });

  it("compiles BsIf to branch + then/else branches", () => {
    const graph = compileFunction([
      bsIf("ExBool", true, [assign("y", "1")], [assign("y", "2")]),
    ]);
    // return(0) + then-assign(1) + else-assign(2) + branch(3) = 4 nodes
    const kinds = graph.nodes.map((n) => n.kind);
    expect(kinds).toContain("branch");
    expect(kinds.filter((k) => k === "assign")).toHaveLength(2);
    expect(graph.entry).toBe(3); // branch is first
  });

  it("marks dw.retrieve() as suspend node", () => {
    const graph = compileFunction([bsCall(["dw_krat", "retrieve"], [["gs_kodxrisi"]])]);
    // return(0) + suspend(1)
    const node = graph.nodes[graph.entry]!;
    expect(node.kind).toBe("suspend");
    expect((node as { effect: string }).effect).toBe("executeSql");
  });

  it("marks open() as suspend node", () => {
    const graph = compileFunction([bsCall(["open"], [["w_main"]])]);
    const node = graph.nodes[graph.entry]!;
    expect(node.kind).toBe("suspend");
    expect((node as { effect: string }).effect).toBe("open");
  });

  it("produces flat graph with no nested control flow", () => {
    const graph = compileFunction([
      assign("x", "1"),
      bsIf("ExBool", true, [assign("y", "2")], [assign("y", "3")]),
      assign("z", "4"),
    ]);
    // Every node should be at the top level — no nested arrays of nodes
    for (const node of graph.nodes) {
      expect(node).not.toHaveProperty("body");
      expect(node).not.toHaveProperty("then");
      expect(node).not.toHaveProperty("else");
    }
  });

  it("tracks source map", () => {
    const graph = compileFunction([assign("x", "1", 5), assign("y", "2", 10)]);
    expect(graph.sourceMap.size).toBeGreaterThan(0);
    // Source map should contain both line numbers at their respective PCs
    const lines = [...graph.sourceMap.values()];
    expect(lines).toContain(5);
    expect(lines).toContain(10);
  });

  it("records suspension points", () => {
    const graph = compileFunction([
      assign("x", "1"),
      bsCall(["dw", "retrieve"], []),
      assign("y", "2"),
    ]);
    expect(graph.suspensionPoints.length).toBeGreaterThanOrEqual(1);
    // Suspension point should be the retrieve call
    const suspendPc = graph.suspensionPoints[0]!;
    expect(graph.nodes[suspendPc]!.kind).toBe("suspend");
  });
});
