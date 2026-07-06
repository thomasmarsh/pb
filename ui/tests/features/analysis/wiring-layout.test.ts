// tests/features/analysis/wiring-layout.test.ts — pure fold + idiom recognizer tests (Plan 149 Phase 3).

import { describe, it, expect } from "vitest";
import type { WireTerm, WiringPayload, Expr } from "@pb/interpreter";
import { layoutWiring, recognizeBranch, prettyExpr, type LayoutBox, type LayoutWire } from "../../../app/src/views/features/analysis/wiring-layout.js";

// ── Fixtures ──────────────────────────────────────────────────────────────────

const EX_LVALUE = (name: string): Expr => ({ tag: "ExLvalue", contents: { segments: [{ name, subscript: null }] } });
const EX_INT = (n: string): Expr => ({ tag: "ExInt", contents: n });

function payload(term: WireTerm, sharedBlocks: Record<string, WireTerm> = {}): WiringPayload {
  return { term, sharedBlocks };
}

// Real corpus shape (f_boolean_to_char): LCompose(LFanIn(t,f), LCompose(LSplitValue,LFork(LId,LEval cond)))
const REAL_BRANCH: WireTerm = {
  tag: "LCompose",
  contents: [
    { tag: "LFanIn", contents: [{ tag: "LId" }, { tag: "LId" }] },
    {
      tag: "LCompose",
      contents: [
        { tag: "LSplitValue" },
        { tag: "LFork", contents: [{ tag: "LId" }, { tag: "LEval", contents: EX_LVALUE("ab_boolean") }] },
      ],
    },
  ],
};

// ── recognizeBranch ───────────────────────────────────────────────────────────

describe("recognizeBranch", () => {
  it("matches the real corpus branch shape and extracts cond/then/else", () => {
    const m = recognizeBranch(REAL_BRANCH);
    expect(m).not.toBeNull();
    expect(m!.cond).toEqual(EX_LVALUE("ab_boolean"));
    expect(m!.thenBranch).toEqual({ tag: "LId" });
    expect(m!.elseBranch).toEqual({ tag: "LId" });
  });

  it("matches identically whether or not the shape sits inside a LLoop body (finding 4: no separate while-case)", () => {
    const inLoop: WireTerm = { tag: "LLoop", contents: REAL_BRANCH };
    expect(inLoop.tag).toBe("LLoop");
    const m = recognizeBranch((inLoop as { tag: "LLoop"; contents: WireTerm }).contents);
    expect(m).not.toBeNull();
  });

  it("returns null for a hand-built non-matching shape (defensive fallback path — never hit by real corpus data, still must not crash)", () => {
    const notABranch: WireTerm = {
      tag: "LCompose",
      contents: [{ tag: "LReturn" }, { tag: "LId" }],
    };
    expect(recognizeBranch(notABranch)).toBeNull();
  });

  it("returns null for a term whose FanIn parent isn't a plain LCompose(LSplitValue, LFork(...)) second arm", () => {
    const almost: WireTerm = {
      tag: "LCompose",
      contents: [
        { tag: "LFanIn", contents: [{ tag: "LId" }, { tag: "LId" }] },
        { tag: "LSplitValue" }, // not wrapped in LCompose(LSplitValue, LFork(...))
      ],
    };
    expect(recognizeBranch(almost)).toBeNull();
  });
});

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

  it("renders ExCall with callee and joined raw-token args", () => {
    const e: Expr = {
      tag: "ExCall",
      callee: { segments: [{ name: "tv_1", subscript: null }, { name: "FindItem", subscript: null }] },
      args: [["ParentTreeItem!"], ["al_Item"]],
    };
    expect(prettyExpr(e)).toBe("tv_1.FindItem(ParentTreeItem!, al_Item)");
  });
});

// ── layoutWiring: one case per WireTerm constructor ──────────────────────────

describe("layoutWiring — per-constructor coverage", () => {
  it("LId: no box, a single wire segment", () => {
    const l = layoutWiring(payload({ tag: "LId" }));
    expect(l.boxes).toHaveLength(0);
    expect(l.wires).toHaveLength(1);
  });

  it("LErasable: renders as an empty wire segment, never crashes (empirically 0/7667 but must be handled)", () => {
    const l = layoutWiring(payload({ tag: "LErasable" }));
    expect(l.boxes).toHaveLength(0);
  });

  it("LReturn: a single terminal box kind=return", () => {
    const l = layoutWiring(payload({ tag: "LReturn" }));
    expect(l.boxes).toHaveLength(1);
    expect(l.boxes[0]!.kind).toBe("return");
    expect(l.boxes[0]!.label).toBe("return");
  });

  it("LEval: a single box kind=eval labeled with the pretty-printed expression", () => {
    const l = layoutWiring(payload({ tag: "LEval", contents: EX_LVALUE("ls_x") }));
    expect(l.boxes).toHaveLength(1);
    expect(l.boxes[0]!.kind).toBe("eval");
    expect(l.boxes[0]!.label).toBe("ls_x");
  });

  it("LAssignWithRhs: a single box kind=assign labeled 'name := expr'", () => {
    const l = layoutWiring(payload({ tag: "LAssignWithRhs", contents: ["ls_x", EX_INT("5")] }));
    expect(l.boxes).toHaveLength(1);
    expect(l.boxes[0]!.kind).toBe("assign");
    expect(l.boxes[0]!.label).toBe("ls_x := 5");
  });

  it("LCall: a single box kind=call labeled 'name(args)'", () => {
    const l = layoutWiring(payload({ tag: "LCall", contents: ["of_helper", [EX_INT("1"), EX_INT("2")]] }));
    expect(l.boxes).toHaveLength(1);
    expect(l.boxes[0]!.kind).toBe("call");
    expect(l.boxes[0]!.label).toBe("of_helper(1, 2)");
  });

  it("LSuspend: a single box kind=suspend labeled 'eff(args)'", () => {
    const l = layoutWiring(payload({ tag: "LSuspend", contents: ["executeSql", []] }));
    expect(l.boxes).toHaveLength(1);
    expect(l.boxes[0]!.kind).toBe("suspend");
    expect(l.boxes[0]!.label).toBe("executeSql()");
  });

  it("LSplitValue (raw, non-idiom-matched): a single box kind=split", () => {
    const l = layoutWiring(payload({ tag: "LSplitValue" }));
    expect(l.boxes).toHaveLength(1);
    expect(l.boxes[0]!.kind).toBe("split");
  });

  it("LCompose: two child boxes plus a connecting seam wire", () => {
    const term: WireTerm = { tag: "LCompose", contents: [{ tag: "LReturn" }, { tag: "LEval", contents: EX_INT("1") }] };
    const l = layoutWiring(payload(term));
    expect(l.boxes).toHaveLength(2);
    expect(l.wires.some((w) => w.id.endsWith(".seam"))).toBe(true);
  });

  it("LFanIn (raw, non-idiom-matched): two lane boxes plus a fork/join region", () => {
    const term: WireTerm = { tag: "LFanIn", contents: [{ tag: "LReturn" }, { tag: "LEval", contents: EX_INT("1") }] };
    const l = layoutWiring(payload(term));
    expect(l.boxes).toHaveLength(2);
    expect(l.regions.some((r) => r.kind === "fanin")).toBe(true);
  });

  it("LFork (raw, non-idiom-matched): two lane boxes plus a fork region", () => {
    const term: WireTerm = { tag: "LFork", contents: [{ tag: "LEval", contents: EX_INT("1") }, { tag: "LEval", contents: EX_INT("2") }] };
    const l = layoutWiring(payload(term));
    expect(l.boxes).toHaveLength(2);
    expect(l.regions.some((r) => r.kind === "fork")).toBe(true);
  });

  it("LLoop: wraps its body in a loop region", () => {
    const l = layoutWiring(payload({ tag: "LLoop", contents: { tag: "LReturn" } }));
    expect(l.regions.some((r) => r.kind === "loop")).toBe(true);
    expect(l.boxes).toHaveLength(1);
  });

  it("LInl inside a LLoop body renders as a continue-cap with a feedback wire", () => {
    const l = layoutWiring(payload({ tag: "LLoop", contents: { tag: "LInl" } }));
    expect(l.boxes[0]!.kind).toBe("continue-cap");
    expect(l.boxes[0]!.label).toBe("continue");
    expect(l.wires.some((w) => w.id.endsWith(".feedback"))).toBe(true);
  });

  it("LInr inside a LLoop body renders as an exit-cap, no feedback wire", () => {
    const l = layoutWiring(payload({ tag: "LLoop", contents: { tag: "LInr" } }));
    expect(l.boxes[0]!.kind).toBe("exit-cap");
    expect(l.boxes[0]!.label).toBe("exit");
    expect(l.wires.some((w) => w.id.endsWith(".feedback"))).toBe(false);
  });

  it("LInl outside any LLoop context falls back to a generic Left label (never seen in corpus, must not crash)", () => {
    const l = layoutWiring(payload({ tag: "LInl" }));
    expect(l.boxes[0]!.kind).toBe("opaque");
    expect(l.boxes[0]!.label).toBe("Left");
  });

  it("LTagged: first occurrence expands the shared block's real content inline", () => {
    const term: WireTerm = { tag: "LTagged", blockId: "b1" };
    const l = layoutWiring(payload(term, { b1: { tag: "LReturn" } }));
    expect(l.boxes).toHaveLength(1);
    expect(l.boxes[0]!.kind).toBe("return");
  });

  it("LTagged: a repeated reference to the same blockId (referenced from two different parents) renders as a jump-box, not a re-expansion", () => {
    // Mirrors the Phase 1 Haskell test's own fixture shape: one LTagged subtree
    // referenced from two different parents.
    const shared: WireTerm = { tag: "LTagged", blockId: "b1" };
    const term: WireTerm = { tag: "LCompose", contents: [shared, shared] };
    const l = layoutWiring(payload(term, { b1: { tag: "LEval", contents: EX_INT("1") } }));
    const jumpBoxes = l.boxes.filter((b) => b.kind === "jump");
    const expandedBoxes = l.boxes.filter((b) => b.kind === "eval");
    expect(expandedBoxes).toHaveLength(1);
    expect(jumpBoxes).toHaveLength(1);
    expect(jumpBoxes[0]!.label).toBe("↩ b1");
  });

  it("throws a clear error if a LTagged blockId is missing from sharedBlocks (malformed payload, should never happen per the Haskell invariant)", () => {
    expect(() => layoutWiring(payload({ tag: "LTagged", blockId: "missing" }))).toThrow(/missing/);
  });
});

// ── layoutWiring: idiom rendering ────────────────────────────────────────────

describe("layoutWiring — if-idiom rendering", () => {
  it("renders the real corpus branch shape as a single if-region with a cond box", () => {
    const l = layoutWiring(payload(REAL_BRANCH));
    const ifRegion = l.regions.find((r) => r.kind === "if");
    expect(ifRegion).toBeDefined();
    expect(l.boxes.some((b) => b.kind === "cond" && b.label === "ab_boolean")).toBe(true);
    // Raw LFanIn/LSplitValue/LFork constructors must not leak through as
    // separate "fanin"/"fork" regions once recognized — only one "if" region.
    expect(l.regions.some((r) => r.kind === "fanin")).toBe(false);
    expect(l.regions.some((r) => r.kind === "fork")).toBe(false);
  });

  it("renders the same if-region whether the branch sits at top level or inside a LLoop (finding 4)", () => {
    const top = layoutWiring(payload(REAL_BRANCH));
    const looped = layoutWiring(payload({ tag: "LLoop", contents: REAL_BRANCH }));
    const topIf = top.regions.filter((r) => r.kind === "if");
    const loopedIf = looped.regions.filter((r) => r.kind === "if");
    expect(topIf).toHaveLength(1);
    expect(loopedIf).toHaveLength(1);
    expect(loopedIf[0]!.width).toBe(topIf[0]!.width);
    expect(loopedIf[0]!.height).toBe(topIf[0]!.height);
  });
});

// ── Invariants ────────────────────────────────────────────────────────────────

function boxesOverlap(a: LayoutBox, b: LayoutBox): boolean {
  return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;
}

// A "real port" is either a box's edge, the overall canvas boundary, or a
// junction where two or more wire segments meet with no box present (e.g. an
// LId "plain wire segment" fusing into a fork/join point) — all three are
// legitimate per the vocabulary table; only a truly dangling, unconnected
// coordinate would fail all three checks.
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

// A hand-built nested fixture: if/elseif-shaped branch inside a loop, with a
// shared merge block referenced twice — exercises composeH + layoutForkJoin +
// layoutLoopRegion + the LTagged jump-box path all in one term.
const NESTED_FIXTURE: WiringPayload = {
  term: {
    tag: "LLoop",
    contents: {
      tag: "LCompose",
      contents: [
        { tag: "LTagged", blockId: "merge" },
        REAL_BRANCH,
      ],
    },
  },
  sharedBlocks: { merge: { tag: "LAssignWithRhs", contents: ["ls_x", EX_INT("1")] } },
};

describe("layoutWiring — invariants", () => {
  it("no two boxes overlap", () => {
    const l = layoutWiring(NESTED_FIXTURE);
    for (let i = 0; i < l.boxes.length; i++) {
      for (let j = i + 1; j < l.boxes.length; j++) {
        expect(boxesOverlap(l.boxes[i]!, l.boxes[j]!)).toBe(false);
      }
    }
  });

  it("every wire endpoint is a real port (canvas edge, a box edge, or a shared wire-to-wire junction)", () => {
    const l = layoutWiring(NESTED_FIXTURE);
    const allPoints = l.wires.flatMap((w) => w.points);
    for (const w of l.wires as LayoutWire[]) {
      for (const p of w.points) {
        expect(isRealPort(p, l.boxes, l.width, l.height, allPoints)).toBe(true);
      }
    }
  });

  it("box ids are deterministic and stable across repeated layout calls", () => {
    const l1 = layoutWiring(NESTED_FIXTURE);
    const l2 = layoutWiring(NESTED_FIXTURE);
    expect(l1.boxes.map((b) => b.id)).toEqual(l2.boxes.map((b) => b.id));
  });
});
