// tests/features/analysis/wiring-layout.test.ts — graph walk tests (Plan 167 Phase 7).

import { describe, it, expect } from "vitest";
import type { WiringNode, WiringGraph, Expr } from "@pb/interpreter";
import {
  layoutWiring, prettyExpr,
  type LayoutBox, type LayoutWire,
} from "../../../app/src/views/features/analysis/wiring-layout.js";

// ── Fixtures ──────────────────────────────────────────────────────────────────

const EX_LVALUE = (name: string): Expr => ({ tag: "ExLvalue", contents: { segments: [{ name, subscript: null }] } });
const EX_INT = (n: string): Expr => ({ tag: "ExInt", contents: n });

function graph(nodes: Record<string, WiringNode>, entry: string): WiringGraph {
  return { nodes, entry };
}

// ── prettyExpr ────────────────────────────────────────────────────────────────

describe("prettyExpr", () => {
  it("renders an lvalue by its dotted segment path", () => {
    expect(prettyExpr(EX_LVALUE("ab_boolean"))).toBe("ab_boolean");
  });

  it("renders a binary op with its PB-style symbol", () => {
    const e: Expr = { tag: "ExBinOp", lhs: EX_LVALUE("al_Item"), op: "BopLe", rhs: EX_INT("0") };
    expect(prettyExpr(e)).toBe("al_Item <= 0");
  });

  it("renders ExNot with a NOT prefix", () => {
    const e: Expr = { tag: "ExNot", contents: { tag: "ExBool", contents: true } };
    expect(prettyExpr(e)).toBe("NOT true");
  });

  it("renders ExCall with callee and joined args", () => {
    const e: Expr = {
      tag: "ExCall",
      callee: { segments: [{ name: "tv_1", subscript: null }, { name: "FindItem", subscript: null }] },
      args: [{ tag: "ExEnum", contents: "ParentTreeItem" }, EX_LVALUE("al_Item")],
    };
    expect(prettyExpr(e)).toBe("tv_1.FindItem(ParentTreeItem!, al_Item)");
  });
});

// ── layoutWiring: per-constructor coverage ────────────────────────────────────

describe("layoutWiring — per-constructor coverage", () => {
  it("WireReturn: a single terminal box kind=return", () => {
    const l = layoutWiring(graph({ w0: { tag: "WireReturn" } }, "w0"));
    expect(l.boxes).toHaveLength(1);
    expect(l.boxes[0]!.kind).toBe("return");
    expect(l.boxes[0]!.label).toBe("return");
  });

  it("WireAssign: a single box kind=assign labeled 'var := rhs'", () => {
    const l = layoutWiring(graph({
      w0: { tag: "WireAssign", var: "ls_x", rhs: EX_INT("5"), next: "w1" },
      w1: { tag: "WireReturn" },
    }, "w0"));
    expect(l.boxes).toHaveLength(2);
    expect(l.boxes[0]!.kind).toBe("assign");
    expect(l.boxes[0]!.label).toBe("ls_x := 5");
    expect(l.boxes[1]!.kind).toBe("return");
  });

  it("WireCond: a single box kind=cond labeled with the pretty-printed expression", () => {
    const l = layoutWiring(graph({
      w0: { tag: "WireCond", expr: EX_LVALUE("ls_x"), next: "w1" },
      w1: { tag: "WireBranch", then: "w2", else: "w3" },
      w2: { tag: "WireReturn" },
      w3: { tag: "WireReturn" },
    }, "w0"));
    expect(l.boxes.some((b) => b.kind === "cond" && b.label === "ls_x")).toBe(true);
  });

  it("WireCall: a single box kind=call labeled 'callee(args)'", () => {
    const l = layoutWiring(graph({
      w0: { tag: "WireCall", callee: "of_helper", args: [EX_INT("1"), EX_INT("2")], next: "w1" },
      w1: { tag: "WireReturn" },
    }, "w0"));
    expect(l.boxes).toHaveLength(2);
    expect(l.boxes[0]!.kind).toBe("call");
    expect(l.boxes[0]!.label).toBe("of_helper(1, 2)");
  });

  it("WireSuspend: a single box kind=suspend labeled 'effect(args)'", () => {
    const l = layoutWiring(graph({
      w0: { tag: "WireSuspend", effect: "executeSql", args: [], next: "w1" },
      w1: { tag: "WireReturn" },
    }, "w0"));
    expect(l.boxes).toHaveLength(2);
    expect(l.boxes[0]!.kind).toBe("suspend");
    expect(l.boxes[0]!.label).toBe("executeSql()");
  });

  it("WireNop: renders as a wire segment (loop header)", () => {
    const l = layoutWiring(graph({
      w0: { tag: "WireNop", next: "w1" },
      w1: { tag: "WireReturn" },
    }, "w0"));
    // WireNop is a loop header — should produce a loop region
    expect(l.regions.some((r) => r.kind === "loop")).toBe(true);
  });
});

// ── layoutWiring: branch rendering ────────────────────────────────────────────

describe("layoutWiring — if-idiom rendering", () => {
  it("renders WireCond → WireBranch as a single if-region with a cond box", () => {
    const l = layoutWiring(graph({
      w0: { tag: "WireCond", expr: EX_LVALUE("ab_boolean"), next: "w1" },
      w1: { tag: "WireBranch", then: "w2", else: "w3" },
      w2: { tag: "WireReturn" },
      w3: { tag: "WireReturn" },
    }, "w0"));
    const ifRegion = l.regions.find((r) => r.kind === "if");
    expect(ifRegion).toBeDefined();
    expect(l.boxes.some((b) => b.kind === "cond" && b.label === "ab_boolean")).toBe(true);
  });

  it("renders a branch with body in both arms", () => {
    const l = layoutWiring(graph({
      w0: { tag: "WireCond", expr: EX_LVALUE("flag"), next: "w1" },
      w1: { tag: "WireBranch", then: "w2", else: "w3" },
      w2: { tag: "WireAssign", var: "x", rhs: EX_INT("1"), next: "w4" },
      w3: { tag: "WireAssign", var: "x", rhs: EX_INT("2"), next: "w4" },
      w4: { tag: "WireReturn" },
    }, "w0"));
    const ifRegion = l.regions.find((r) => r.kind === "if");
    expect(ifRegion).toBeDefined();
    // Both arms should have assign boxes
    expect(l.boxes.filter((b) => b.kind === "assign")).toHaveLength(2);
    // Join at w4 (return)
    expect(l.boxes.some((b) => b.kind === "return")).toBe(true);
  });
});

// ── layoutWiring: elseif chain ────────────────────────────────────────────────

describe("layoutWiring — elseif-chain rendering", () => {
  it("renders a 3-clause elseif chain as a single flat ladder region", () => {
    // WireCond → WireBranch, else → WireCond → WireBranch, else → WireCond → WireBranch
    const l = layoutWiring(graph({
      w0: { tag: "WireCond", expr: EX_INT("1"), next: "w1" },
      w1: { tag: "WireBranch", then: "w_t1", else: "w2" },
      w_t1: { tag: "WireReturn" },
      w2: { tag: "WireCond", expr: EX_INT("2"), next: "w3" },
      w3: { tag: "WireBranch", then: "w_t2", else: "w4" },
      w_t2: { tag: "WireReturn" },
      w4: { tag: "WireCond", expr: EX_INT("3"), next: "w5" },
      w5: { tag: "WireBranch", then: "w_t3", else: "w_e" },
      w_t3: { tag: "WireReturn" },
      w_e: { tag: "WireReturn" },
    }, "w0"));
    const ifRegions = l.regions.filter((r) => r.kind === "if");
    expect(ifRegions).toHaveLength(1);
    expect(l.boxes.filter((b) => b.kind === "cond")).toHaveLength(3);
  });
});

// ── Invariants ────────────────────────────────────────────────────────────────

function boxesOverlap(a: LayoutBox, b: LayoutBox): boolean {
  return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;
}

function isRealPort(
  point: { x: number; y: number },
  boxes: LayoutBox[],
  width: number,
  height: number,
  allPoints: { x: number; y: number }[],
): boolean {
  const onCanvasEdge = point.x === 0 || point.x === width || point.y === 0 || point.y === height;
  const onBoxEdge = boxes.some(
    (b) =>
      (point.x === b.x || point.x === b.x + b.width) && point.y >= b.y && point.y <= b.y + b.height,
  );
  const sharedWithAnotherWire = allPoints.filter((p) => p.x === point.x && p.y === point.y).length > 1;
  return onCanvasEdge || onBoxEdge || sharedWithAnotherWire;
}

const NESTED_GRAPH: WiringGraph = {
  nodes: {
    w0: { tag: "WireNop", next: "w1" },
    w1: { tag: "WireAssign", var: "ls_x", rhs: EX_INT("1"), next: "w2" },
    w2: { tag: "WireCond", expr: EX_LVALUE("ab_boolean"), next: "w3" },
    w3: { tag: "WireBranch", then: "w4", else: "w5" },
    w4: { tag: "WireReturn" },
    w5: { tag: "WireReturn" },
  },
  entry: "w0",
};

describe("layoutWiring — invariants", () => {
  it("no two boxes overlap", () => {
    const l = layoutWiring(NESTED_GRAPH);
    for (let i = 0; i < l.boxes.length; i++) {
      for (let j = i + 1; j < l.boxes.length; j++) {
        expect(boxesOverlap(l.boxes[i]!, l.boxes[j]!)).toBe(false);
      }
    }
  });

  it("every wire endpoint is a real port (canvas edge, a box edge, or a shared wire-to-wire junction)", () => {
    const l = layoutWiring(NESTED_GRAPH);
    const allPoints = l.wires.flatMap((w) => w.points);
    for (const w of l.wires as LayoutWire[]) {
      for (const p of w.points) {
        expect(isRealPort(p, l.boxes, l.width, l.height, allPoints)).toBe(true);
      }
    }
  });

  it("box ids are deterministic and stable across repeated layout calls", () => {
    const l1 = layoutWiring(NESTED_GRAPH);
    const l2 = layoutWiring(NESTED_GRAPH);
    expect(l1.boxes.map((b) => b.id)).toEqual(l2.boxes.map((b) => b.id));
  });
});

// ── Box sizing: width must scale with label length ──────────────────────────

describe("layoutWiring — box width scales with label length", () => {
  it("a long call-expression label produces a visibly wider box than a short one", () => {
    const shortLabel = layoutWiring(graph({
      w0: { tag: "WireCond", expr: EX_LVALUE("x"), next: "w1" },
      w1: { tag: "WireBranch", then: "w2", else: "w3" },
      w2: { tag: "WireReturn" },
      w3: { tag: "WireReturn" },
    }, "w0"));
    const longLabel = layoutWiring(graph({
      w0: { tag: "WireCall", callee: "of_createwhere", args: [EX_LVALUE("al_startrow"), EX_LVALUE("al_endrow"), EX_LVALUE("ls_where_datefinal")], next: "w1" },
      w1: { tag: "WireReturn" },
    }, "w0"));
    const shortCond = shortLabel.boxes.find((b) => b.kind === "cond");
    const longCall = longLabel.boxes.find((b) => b.kind === "call");
    expect(shortCond).toBeDefined();
    expect(longCall).toBeDefined();
    expect(longCall!.width).toBeGreaterThan(shortCond!.width);
  });
});

// ── Shared tail: node referenced from both branches ──────────────────────────

describe("layoutWiring — shared tail rendering", () => {
  it("a node referenced by both branches is rendered once, with jump-boxes from the other branch", () => {
    const l = layoutWiring(graph({
      w0: { tag: "WireCond", expr: EX_LVALUE("flag"), next: "w1" },
      w1: { tag: "WireBranch", then: "w2", else: "w3" },
      w2: { tag: "WireAssign", var: "a", rhs: EX_INT("1"), next: "w4" },
      w3: { tag: "WireAssign", var: "b", rhs: EX_INT("2"), next: "w4" },
      w4: { tag: "WireReturn" },
    }, "w0"));
    // w4 (return) should be rendered once
    expect(l.boxes.filter((b) => b.kind === "return")).toHaveLength(1);
    // Both arms should have their assign boxes
    expect(l.boxes.filter((b) => b.kind === "assign")).toHaveLength(2);
  });
});

// ── Loop back-edge rendering ─────────────────────────────────────────────────

describe("layoutWiring — loop back-edge rendering", () => {
  it("a loop with a back-edge renders a loop region and a continue-cap feedback wire", () => {
    const l = layoutWiring(graph({
      w0: { tag: "WireNop", next: "w1" },
      w1: { tag: "WireCond", expr: EX_LVALUE("done"), next: "w2" },
      w2: { tag: "WireBranch", then: "w3", else: "w0" },  // else back-edges to loop header
      w3: { tag: "WireReturn" },
    }, "w0"));
    expect(l.regions.some((r) => r.kind === "loop")).toBe(true);
    // The back-edge (else → w0) should render as a continue-cap
    expect(l.boxes.some((b) => b.kind === "continue-cap")).toBe(true);
  });
});
