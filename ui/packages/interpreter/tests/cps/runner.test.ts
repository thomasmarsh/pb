// tests/core/cps/runner.test.ts — Tests for the CPS step driver.

import { describe, it, expect } from "vitest";
import { Effect } from "@pb/core";
import { step, type CpsEnv } from "../../src/cps/runner.js";
import type { CpsGraph, CpsNode } from "../../src/cps/types.js";
import { makeVarEnv, flattenVarEnv } from "../../src/cps/var-env.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeGraph(nodes: CpsNode[], entry = 0): CpsGraph {
  return {
    nodes,
    entry,
    suspensionPoints: nodes.reduce<number[]>(
      (acc, n, i) => (n.kind === "suspend" ? [...acc, i] : acc),
      [],
    ),
    sourceMap: new Map(),
  };
}

const nullEnv: CpsEnv = {
  executeSql: () => Effect.none(),
  open: () => Effect.none(),
};

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("step driver", () => {
  it("execute return node exits", () => {
    const graph = makeGraph([{ kind: "return" }]);
    const result = step(graph, 0, makeVarEnv(), nullEnv);
    expect(result).toBeNull();
  });

  it("execute assign node updates variable", () => {
    const graph = makeGraph([
      { kind: "assign", var: "x", rhs: { tag: "ExInt", contents: "42" } as any, next: 1 },
      { kind: "return" },
    ]);
    const varEnv = makeVarEnv();
    step(graph, 0, varEnv, nullEnv);
    expect(flattenVarEnv(varEnv).x).toBe(42);
  });

  it("execute branch node follows correct path", () => {
    const graph = makeGraph([
      { kind: "branch", cond: { tag: "ExBool", contents: true } as any, then_: 1, else_: 2 },
      { kind: "assign", var: "path", rhs: { tag: "ExStr", contents: "then" } as any, next: 3 },
      { kind: "assign", var: "path", rhs: { tag: "ExStr", contents: "else" } as any, next: 3 },
      { kind: "return" },
    ]);
    const varEnv = makeVarEnv();
    step(graph, 0, varEnv, nullEnv);
    expect(flattenVarEnv(varEnv).path).toBe("then");
  });

  it("execute branch node follows else path when false", () => {
    const graph = makeGraph([
      { kind: "branch", cond: { tag: "ExBool", contents: false } as any, then_: 1, else_: 2 },
      { kind: "assign", var: "path", rhs: { tag: "ExStr", contents: "then" } as any, next: 3 },
      { kind: "assign", var: "path", rhs: { tag: "ExStr", contents: "else" } as any, next: 3 },
      { kind: "return" },
    ]);
    const varEnv = makeVarEnv();
    step(graph, 0, varEnv, nullEnv);
    expect(flattenVarEnv(varEnv).path).toBe("else");
  });

  it("execute goto node jumps to target", () => {
    const graph = makeGraph([
      { kind: "goto", target: 2 },
      { kind: "assign", var: "x", rhs: { tag: "ExInt", contents: "1" } as any, next: 3 },
      { kind: "assign", var: "x", rhs: { tag: "ExInt", contents: "2" } as any, next: 3 },
      { kind: "return" },
    ]);
    const varEnv = makeVarEnv();
    step(graph, 0, varEnv, nullEnv);
    expect(flattenVarEnv(varEnv).x).toBe(2);
  });

  it("execute call node invokes builtin", () => {
    const graph = makeGraph([
      {
        kind: "call",
        callee: "len",
        args: [{ tag: "ExStr", contents: "hello" } as any],
        result: "result",
        next: 1,
      },
      { kind: "return" },
    ]);
    const varEnv = makeVarEnv();
    step(graph, 0, varEnv, nullEnv);
    expect(flattenVarEnv(varEnv).result).toBe(5);
  });

  it("execute call node skips unknown function", () => {
    const graph = makeGraph([
      {
        kind: "call",
        callee: "unknown_fn",
        args: [],
        result: "result",
        next: 1,
      },
      { kind: "return" },
    ]);
    const varEnv = makeVarEnv();
    step(graph, 0, varEnv, nullEnv);
    expect(flattenVarEnv(varEnv).result).toBeUndefined();
  });

  it("execute suspend node returns Effect", () => {
    const graph = makeGraph([
      {
        kind: "suspend",
        effect: "executeSql",
        args: [{ tag: "ExStr", contents: "SELECT 1" } as any],
        continuation: 1,
      },
      { kind: "return" },
    ]);
    const result = step(graph, 0, makeVarEnv(), nullEnv);
    expect(result).not.toBeNull();
  });

  it("execute nop node continues to next", () => {
    const graph = makeGraph([
      { kind: "nop", next: 1 },
      { kind: "assign", var: "x", rhs: { tag: "ExInt", contents: "1" } as any, next: 2 },
      { kind: "return" },
    ]);
    const varEnv = makeVarEnv();
    step(graph, 0, varEnv, nullEnv);
    expect(flattenVarEnv(varEnv).x).toBe(1);
  });

  // Plan 115 item 2: CpsCallProc emits a cps-dispatch resume action.
  it("execute callproc node returns cps-dispatch effect", () => {
    const graph = makeGraph([
      {
        kind: "callproc",
        callee: "super::open",
        args: [],
        next: 1,
      },
      { kind: "return" },
    ]);
    const result = step(graph, 0, makeVarEnv(), nullEnv);
    expect(result).not.toBeNull();
    let received: unknown = null;
    result!.execute((a) => { received = a; });
    expect(received).toEqual({
      tag: "cps-dispatch",
      callee: "super::open",
      args: [],
      resumePc: 1,
    });
  });

  it("execute callproc triggerevent evaluates args", () => {
    const graph = makeGraph([
      {
        kind: "callproc",
        callee: "triggerevent",
        args: [{ tag: "ExStr", contents: "ie_retrieve" } as any],
        next: 1,
      },
      { kind: "return" },
    ]);
    const result = step(graph, 0, makeVarEnv(), nullEnv);
    expect(result).not.toBeNull();
    let received: unknown = null;
    result!.execute((a) => { received = a; });
    expect(received).toEqual({
      tag: "cps-dispatch",
      callee: "triggerevent",
      args: ["ie_retrieve"],
      resumePc: 1,
    });
  });

  it("chained assigns execute in order", () => {
    const graph = makeGraph([
      { kind: "assign", var: "a", rhs: { tag: "ExInt", contents: "1" } as any, next: 1 },
      { kind: "assign", var: "b", rhs: { tag: "ExInt", contents: "2" } as any, next: 2 },
      { kind: "assign", var: "c", rhs: { tag: "ExInt", contents: "3" } as any, next: 3 },
      { kind: "return" },
    ]);
    const varEnv = makeVarEnv();
    step(graph, 0, varEnv, nullEnv);
    expect(flattenVarEnv(varEnv)).toEqual({ a: 1, b: 2, c: 3 });
  });
});
