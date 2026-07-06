// features/analysis/wiring-layout.ts — pure term → positioned-diagram fold (Plan 149 Phase 3).
//
// No DOM, no Solid. Consumes a WiringPayload (WireTerm + shared-block side
// table, mirroring PB.Analysis.GraphBuilder.LowCat/WiringPayload) and produces
// absolute-coordinate boxes/wires/regions for WiringCore.tsx to render as SVG.
//
// Every subterm is folded to a Diagram exposing exactly one entry port (left)
// and one exit port (right) — even LFanIn/LFork/LSplitValue, which are only
// ever reached via the raw-constructor fallback (real corpus terms are
// 100%-matched by recognizeBranch per Plan 149 Phase 0 finding 4). This
// uniform 1-in/1-out contract is what makes LCompose stacking a simple
// left-to-right fuse; the fallback's exposed single exit for LFork (which is
// structurally two parallel outputs) is a deliberate simplification — dead
// code on real data, "correct, just uglier" per the plan's own tolerance.

import type { WireTerm, WiringPayload, Expr, Lvalue, BinOp } from "@pb/interpreter";

export type BoxKind =
  | "eval" | "assign" | "call" | "suspend" | "return" | "cond"
  | "continue-cap" | "exit-cap" | "jump" | "split" | "opaque";

export type RegionKind = "if" | "loop" | "fanin" | "fork";

export interface Port { x: number; y: number }

export interface LayoutBox {
  id: string;
  kind: BoxKind;
  label: string;
  x: number; y: number; width: number; height: number;
}

export interface LayoutWire {
  id: string;
  points: Port[];
}

export interface LayoutRegion {
  id: string;
  kind: RegionKind;
  label: string;
  x: number; y: number; width: number; height: number;
}

export interface WiringLayout {
  boxes: LayoutBox[];
  wires: LayoutWire[];
  regions: LayoutRegion[];
  width: number;
  height: number;
}

export interface BranchIdiom {
  cond: Expr;
  thenBranch: WireTerm;
  elseBranch: WireTerm;
}

// ── Idiom recognition (presentation only, never semantic) ───────────────────
//
// The `branch` combinator (CatOp.hs:89-90) always compiles to exactly this
// shape: LCompose(LFanIn(t,f), LCompose(LSplitValue, LFork(LId, LEval cond))).
// Verified 5374/5374 real branch/while join sites match it (Plan 149 Phase 0
// finding 4) — no separate case needed for a branch nested inside a loop.

export function recognizeBranch(term: WireTerm): BranchIdiom | null {
  if (term.tag !== "LCompose") return null;
  const [g, f] = term.contents;
  if (g.tag !== "LFanIn") return null;
  if (f.tag !== "LCompose") return null;
  const [split, fork] = f.contents;
  if (split.tag !== "LSplitValue") return null;
  if (fork.tag !== "LFork") return null;
  const [idPart, evalPart] = fork.contents;
  if (idPart.tag !== "LId") return null;
  if (evalPart.tag !== "LEval") return null;
  const [thenBranch, elseBranch] = g.contents;
  return { cond: evalPart.contents, thenBranch, elseBranch };
}

// ── Expression pretty-printing (box labels only) ─────────────────────────────

const BIN_OP_SYMBOL: Record<BinOp, string> = {
  BopAdd: "+", BopSub: "-", BopMul: "*", BopDiv: "/", BopPow: "^",
  BopEq: "=", BopNe: "<>", BopLt: "<", BopGt: ">", BopLe: "<=", BopGe: ">=",
  BopAnd: "AND", BopOr: "OR", BopXor: "XOR",
};

function prettyLvalue(lv: Lvalue): string {
  return lv.segments
    .map((s) => (s.subscript ? `${s.name}[${s.subscript.join(",")}]` : s.name))
    .join(".");
}

function prettyArgs(args: string[][]): string {
  return args.map((a) => a.join(" ")).join(", ");
}

export function prettyExpr(e: Expr): string {
  switch (e.tag) {
  case "ExBool":       return e.contents ? "true" : "false";
  case "ExInt":        return e.contents;
  case "ExReal":       return e.contents;
  case "ExStr":        return `"${e.contents}"`;
  case "ExDate":       return e.contents;
  case "ExTime":       return e.contents;
  case "ExNull":       return "null";
  case "ExEnum":       return `${e.contents}!`;
  case "ExLvalue":     return prettyLvalue(e.contents);
  case "ExCall":       return `${prettyLvalue(e.callee)}(${prettyArgs(e.args)})`;
  case "ExMethodCall": return `${prettyExpr(e.receiver)}.${e.method}(${prettyArgs(e.args)})`;
  case "ExDispatch":   return `${e.contents.object ? prettyLvalue(e.contents.object) + "." : ""}${e.contents.name}(${prettyArgs(e.contents.args)})`;
  case "ExCreate":     return `CREATE ${e.contents}`;
  case "ExCreateUsing": return `CREATE USING ${prettyExpr(e.contents)}`;
  case "ExArray":      return `{${e.contents.map(prettyExpr).join(", ")}}`;
  case "ExBinOp":      return `${prettyExpr(e.lhs)} ${BIN_OP_SYMBOL[e.op]} ${prettyExpr(e.rhs)}`;
  case "ExNot":        return `NOT ${prettyExpr(e.contents)}`;
  case "ExNeg":        return `-${prettyExpr(e.contents)}`;
  case "ExHostVar":    return `:${prettyLvalue(e.contents)}`;
  case "ExRaw":        return e.contents.join(" ");
  }
}

// ── Geometry constants ───────────────────────────────────────────────────────

const BOX_W = 160;
const BOX_H = 40;
const SEG_W = 28;
const LANE_GAP = 16;
const REGION_PAD = 14;

// ── Diagram: the fold's intermediate representation ─────────────────────────
// Every Diagram exposes exactly one left entry port (x=0, y=entryY) and one
// right exit port (x=width, y=exitY), regardless of internal complexity.

interface Diagram {
  width: number;
  height: number;
  entryY: number;
  exitY: number;
  boxes: LayoutBox[];
  wires: LayoutWire[];
  regions: LayoutRegion[];
}

function translate(d: Diagram, dx: number, dy: number): Diagram {
  return {
    width: d.width,
    height: d.height,
    entryY: d.entryY + dy,
    exitY: d.exitY + dy,
    boxes: d.boxes.map((b) => ({ ...b, x: b.x + dx, y: b.y + dy })),
    wires: d.wires.map((w) => ({ ...w, points: w.points.map((p) => ({ x: p.x + dx, y: p.y + dy })) })),
    regions: d.regions.map((r) => ({ ...r, x: r.x + dx, y: r.y + dy })),
  };
}

function leafBox(id: string, kind: BoxKind, label: string): Diagram {
  return {
    width: BOX_W, height: BOX_H, entryY: BOX_H / 2, exitY: BOX_H / 2,
    boxes: [{ id, kind, label, x: 0, y: 0, width: BOX_W, height: BOX_H }],
    wires: [], regions: [],
  };
}

function wireOnly(id: string): Diagram {
  const height = 4;
  return {
    width: SEG_W, height, entryY: height / 2, exitY: height / 2,
    boxes: [],
    wires: [{ id, points: [{ x: 0, y: height / 2 }, { x: SEG_W, y: height / 2 }] }],
    regions: [],
  };
}

// Sequential composition: f executes first (left), g second (right). Mirrors
// `LCompose g f` — f then g. Aligns f's exit port with g's entry port,
// shifting whichever diagram sits higher so the seam wire is a straight line.
function composeH(idPrefix: string, f: Diagram, g: Diagram): Diagram {
  const fOffsetY = Math.max(0, g.entryY - f.exitY);
  const gOffsetY = Math.max(0, f.exitY - g.entryY);
  const fT = translate(f, 0, fOffsetY);
  const gT = translate(g, f.width + SEG_W, gOffsetY);
  const seamY = fT.exitY;
  const seam: LayoutWire = {
    id: `${idPrefix}.seam`,
    points: [{ x: f.width, y: seamY }, { x: f.width + SEG_W, y: seamY }],
  };
  return {
    width: f.width + SEG_W + g.width,
    height: Math.max(f.height + fOffsetY, g.height + gOffsetY),
    entryY: fT.entryY,
    exitY: gT.exitY,
    boxes: [...fT.boxes, ...gT.boxes],
    wires: [...fT.wires, seam, ...gT.wires],
    regions: [...fT.regions, ...gT.regions],
  };
}

// Stacks two diagrams vertically (top above bottom, both starting at x=SEG_W)
// behind one shared entry fork-point and one shared exit join-point — the
// "two stacked branch regions merging into one output wire" shape used by
// both the if-region (with a cond box prefix) and the raw LFanIn/LFork
// fallback (never hit on real corpus data, per Phase 0 finding 4).
function layoutForkJoin(path: string, kind: RegionKind, label: string, top: Diagram, bottom: Diagram, addRegion = true): Diagram {
  const lanesX = SEG_W;
  const topT = translate(top, lanesX, 0);
  const bottomT = translate(bottom, lanesX, top.height + LANE_GAP);
  const lanesWidth = Math.max(top.width, bottom.width);
  const forkY = (topT.entryY + bottomT.entryY) / 2;
  const joinX = lanesX + lanesWidth + SEG_W;
  const joinY = (topT.exitY + bottomT.exitY) / 2;
  const forkTop: LayoutWire = { id: `${path}.forkT`, points: [{ x: 0, y: forkY }, { x: lanesX, y: topT.entryY }] };
  const forkBottom: LayoutWire = { id: `${path}.forkB`, points: [{ x: 0, y: forkY }, { x: lanesX, y: bottomT.entryY }] };
  const joinTop: LayoutWire = { id: `${path}.joinT`, points: [{ x: lanesX + lanesWidth, y: topT.exitY }, { x: joinX, y: joinY }] };
  const joinBottom: LayoutWire = { id: `${path}.joinB`, points: [{ x: lanesX + lanesWidth, y: bottomT.exitY }, { x: joinX, y: joinY }] };
  const height = top.height + LANE_GAP + bottom.height;
  const region: LayoutRegion = { id: `${path}.region`, kind, label, x: 0, y: 0, width: joinX, height };
  return {
    width: joinX,
    height,
    entryY: forkY,
    exitY: joinY,
    boxes: [...topT.boxes, ...bottomT.boxes],
    wires: [forkTop, forkBottom, ...topT.wires, ...bottomT.wires, joinTop, joinBottom],
    regions: addRegion ? [...topT.regions, ...bottomT.regions, region] : [...topT.regions, ...bottomT.regions],
  };
}

function layoutIfRegion(branch: BranchIdiom, path: string, ctx: FoldCtx): Diagram {
  const condD = leafBox(`${path}.cond`, "cond", prettyExpr(branch.cond));
  const thenD = layoutTerm(branch.thenBranch, `${path}.then`, ctx);
  const elseD = layoutTerm(branch.elseBranch, `${path}.else`, ctx);
  // addRegion=false: the fork/join lanes are wrapped by this function's own
  // "if" region below, spanning cond box + lanes together — an inner region
  // here would be a redundant duplicate of the same "if" kind.
  const forkJoin = layoutForkJoin(path, "if", "if", thenD, elseD, false);
  const combined = composeH(path, condD, forkJoin);
  const region: LayoutRegion = { id: `${path}.if-region`, kind: "if", label: "if", x: 0, y: 0, width: combined.width, height: combined.height };
  return { ...combined, regions: [...combined.regions, region] };
}

// Wraps a loop body in a rounded region. LInl-tagged ("continue") boxes
// inside the body get a feedback wire routed back to the region's own entry
// port instead of the ordinary rightward exit wire composeH would otherwise
// have given them (their box still has a normal exit port geometrically —
// this just adds the extra loop-back wire on top; it does not repurpose the
// existing rightward seam, which is harmless dead geometry for a continue box).
function layoutLoopRegion(path: string, body: Diagram): Diagram {
  const bodyT = translate(body, REGION_PAD, REGION_PAD);
  const feedbackWires: LayoutWire[] = bodyT.boxes
    .filter((b) => b.kind === "continue-cap")
    .map((b) => ({
      id: `${b.id}.feedback`,
      points: [
        { x: b.x + b.width, y: b.y + b.height / 2 },
        { x: REGION_PAD, y: bodyT.entryY },
      ],
    }));
  const width = bodyT.width + 2 * REGION_PAD;
  const height = bodyT.height + 2 * REGION_PAD;
  const region: LayoutRegion = { id: `${path}.loop-region`, kind: "loop", label: "loop", x: 0, y: 0, width, height };
  return {
    width, height,
    entryY: bodyT.entryY,
    exitY: bodyT.exitY,
    boxes: bodyT.boxes,
    wires: [...bodyT.wires, ...feedbackWires],
    regions: [...bodyT.regions, region],
  };
}

interface FoldCtx {
  sharedBlocks: Record<string, WireTerm>;
  seen: Set<string>;
  insideLoop: boolean;
}

function layoutTerm(term: WireTerm, path: string, ctx: FoldCtx): Diagram {
  const branch = recognizeBranch(term);
  if (branch) return layoutIfRegion(branch, path, ctx);

  switch (term.tag) {
  case "LId":          return wireOnly(path);
  case "LErasable":    return wireOnly(path);
  case "LReturn":      return leafBox(path, "return", "return");
  case "LInl":         return leafBox(path, ctx.insideLoop ? "continue-cap" : "opaque", ctx.insideLoop ? "continue" : "Left");
  case "LInr":         return leafBox(path, ctx.insideLoop ? "exit-cap" : "opaque", ctx.insideLoop ? "exit" : "Right");
  case "LSplitValue":  return leafBox(path, "split", "split");
  case "LEval":        return leafBox(path, "eval", prettyExpr(term.contents));
  case "LAssignWithRhs": {
    const [name, expr] = term.contents;
    return leafBox(path, "assign", `${name} := ${prettyExpr(expr)}`);
  }
  case "LCall": {
    const [name, args] = term.contents;
    return leafBox(path, "call", `${name}(${args.map(prettyExpr).join(", ")})`);
  }
  case "LSuspend": {
    const [eff, args] = term.contents;
    return leafBox(path, "suspend", `${eff}(${args.map(prettyExpr).join(", ")})`);
  }
  case "LCompose": {
    const [g, f] = term.contents;
    const fD = layoutTerm(f, `${path}.f`, ctx);
    const gD = layoutTerm(g, `${path}.g`, ctx);
    return composeH(path, fD, gD);
  }
  case "LFanIn": {
    const [t, e] = term.contents;
    const tD = layoutTerm(t, `${path}.t`, ctx);
    const eD = layoutTerm(e, `${path}.e`, ctx);
    return layoutForkJoin(path, "fanin", "fanin", tD, eD);
  }
  case "LFork": {
    const [l, r] = term.contents;
    const lD = layoutTerm(l, `${path}.l`, ctx);
    const rD = layoutTerm(r, `${path}.r`, ctx);
    return layoutForkJoin(path, "fork", "fork", lD, rD);
  }
  case "LLoop": {
    const bodyD = layoutTerm(term.contents, `${path}.body`, { ...ctx, insideLoop: true });
    return layoutLoopRegion(path, bodyD);
  }
  case "LTagged": {
    const { blockId } = term;
    if (ctx.seen.has(blockId)) return leafBox(path, "jump", `↩ ${blockId}`);
    ctx.seen.add(blockId);
    const inner = ctx.sharedBlocks[blockId];
    if (!inner) throw new Error(`wiring-layout: LTagged references unknown blockId ${blockId}`);
    return layoutTerm(inner, `${path}.shared`, ctx);
  }
  }
}

export function layoutWiring(payload: WiringPayload): WiringLayout {
  const ctx: FoldCtx = { sharedBlocks: payload.sharedBlocks, seen: new Set(), insideLoop: false };
  const d = layoutTerm(payload.term, "0", ctx);
  return { boxes: d.boxes, wires: d.wires, regions: d.regions, width: d.width, height: d.height };
}
