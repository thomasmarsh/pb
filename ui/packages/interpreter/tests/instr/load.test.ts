// tests/interpreter/instr/load.test.ts — Tests for loadInstrGraph().

import { describe, it, expect } from "vitest";
import { loadInstrGraph } from "../../src/instr/load.js";

describe("loadInstrGraph", () => {
  it("maps InstrAssign tag → kind assign with renamed fields", () => {
    const raw = {
      nodes: [
        { tag: "InstrReturn" },
        { tag: "InstrAssign", var: "x", rhs: { tag: "ExInt", contents: "1" }, next: 0 },
      ],
      entry: 1,
      suspensionPoints: [],
      sourceMap: [],
    };
    const g = loadInstrGraph(raw);
    expect(g.nodes).toHaveLength(2);
    const assign = g.nodes[1]!;
    expect(assign.kind).toBe("assign");
    if (assign.kind === "assign") {
      expect(assign.var).toBe("x");
      expect(assign.next).toBe(0);
    }
  });

  it("maps InstrBranch thenPc/elsePc → then_/else_", () => {
    const raw = {
      nodes: [
        { tag: "InstrReturn" },
        { tag: "InstrBranch", cond: { tag: "ExBool", contents: true }, thenPc: 2, elsePc: 0 },
        { tag: "InstrAssign", var: "x", rhs: { tag: "ExInt", contents: "1" }, next: 0 },
      ],
      entry: 1,
      suspensionPoints: [],
      sourceMap: [],
    };
    const g = loadInstrGraph(raw);
    const branch = g.nodes[1]!;
    expect(branch.kind).toBe("branch");
    if (branch.kind === "branch") {
      expect(branch.then_).toBe(2);
      expect(branch.else_).toBe(0);
    }
  });

  it("converts sourceMap array-of-pairs into a Map", () => {
    const raw = {
      nodes: [
        { tag: "InstrReturn" },
        { tag: "InstrAssign", var: "x", rhs: { tag: "ExInt", contents: "1" }, next: 0 },
      ],
      entry: 1,
      suspensionPoints: [],
      sourceMap: [[1, 42]],
    };
    const g = loadInstrGraph(raw);
    expect(g.sourceMap).toBeInstanceOf(Map);
    expect(g.sourceMap.get(1)).toBe(42);
  });

  it("preserves suspensionPoints array", () => {
    const raw = {
      nodes: [
        { tag: "InstrReturn" },
        {
          tag: "InstrSuspend",
          effect: "executeSql",
          args: [],
          continuation: 0,
        },
      ],
      entry: 1,
      suspensionPoints: [1],
      sourceMap: [],
    };
    const g = loadInstrGraph(raw);
    expect(g.suspensionPoints).toEqual([1]);
    const suspend = g.nodes[1]!;
    expect(suspend.kind).toBe("suspend");
    if (suspend.kind === "suspend") {
      expect(suspend.effect).toBe("executeSql");
    }
  });

  // Plan 115 item 2: InstrCallProc deserialization.
  it("maps InstrCallProc tag → kind callproc with callee/args/next", () => {
    const raw = {
      nodes: [
        { tag: "InstrReturn" },
        {
          tag: "InstrCallProc",
          callee: "super::open",
          args: [],
          next: 0,
        },
      ],
      entry: 1,
      suspensionPoints: [],
      sourceMap: [],
    };
    const g = loadInstrGraph(raw);
    const callproc = g.nodes[1]!;
    expect(callproc.kind).toBe("callproc");
    if (callproc.kind === "callproc") {
      expect(callproc.callee).toBe("super::open");
      expect(callproc.args).toEqual([]);
      expect(callproc.next).toBe(0);
    }
  });

  it("maps InstrCallProc triggerevent with string-literal arg", () => {
    const raw = {
      nodes: [
        { tag: "InstrReturn" },
        {
          tag: "InstrCallProc",
          callee: "triggerevent",
          args: [{ tag: "ExStr", contents: "ie_retrieve" }],
          next: 0,
        },
      ],
      entry: 1,
      suspensionPoints: [],
      sourceMap: [],
    };
    const g = loadInstrGraph(raw);
    const callproc = g.nodes[1]!;
    expect(callproc.kind).toBe("callproc");
    if (callproc.kind === "callproc") {
      expect(callproc.callee).toBe("triggerevent");
      expect(callproc.args).toHaveLength(1);
      expect(callproc.next).toBe(0);
    }
  });
});
