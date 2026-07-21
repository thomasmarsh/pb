// features/analysis/wiring-layout.ts — pure graph → positioned-diagram walk (Plan 167 Phase 7).
//
// No DOM, no Solid. Consumes a WiringGraph (flat, name-addressed graph of
// WiringNode values, mirroring PB.Analysis.GraphBuilder.WiringGraph) and
// produces absolute-coordinate boxes/wires/regions for WiringCore.tsx to
// render as SVG.
//
// Every node is folded to a Diagram exposing exactly one entry port (left)
// and one exit port (right). The graph is walked from `entry`, following
// `next` references. Branches fork into two lanes that reconverge at a
// shared join point. Back-edges (loops) render as feedback wires.

import type { WiringNode, WiringGraph, Expr, Lvalue, BinOp } from "@pb/interpreter";

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

function prettyExprArgs(args: Expr[]): string {
  return args.map(prettyExpr).join(", ");
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
  case "ExCall":       return `${prettyLvalue(e.callee)}(${prettyExprArgs(e.args)})`;
  case "ExMethodCall": return `${prettyExpr(e.receiver)}.${e.method}(${prettyExprArgs(e.args)})`;
  case "ExDispatch":   return `${e.contents.object ? prettyLvalue(e.contents.object) + "." : ""}${e.contents.name}(${prettyExprArgs(e.contents.args)})`;
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

const BOX_H = 40;
const BOX_MIN_W = 90;
const BOX_LABEL_PAD = 20; // horizontal padding inside the box, 10px each side
const CHAR_W = 6.6; // approx glyph width at the box label's 11px monospace font-size
const SEG_W = 28;
const LANE_GAP = 16;
const REGION_PAD = 14;

// ── Diagram: the walk's intermediate representation ──────────────────────────
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
  const width = Math.max(BOX_MIN_W, Math.ceil(label.length * CHAR_W) + BOX_LABEL_PAD);
  return {
    width, height: BOX_H, entryY: BOX_H / 2, exitY: BOX_H / 2,
    boxes: [{ id, kind, label, x: 0, y: 0, width, height: BOX_H }],
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

function layoutLadder(path: string, kind: RegionKind, label: string, lanes: Diagram[], addRegion = true): Diagram {
  const lanesX = SEG_W;
  let y = 0;
  const translated: Diagram[] = [];
  for (const lane of lanes) {
    translated.push(translate(lane, lanesX, y));
    y += lane.height + LANE_GAP;
  }
  const height = y - LANE_GAP;
  const lanesWidth = Math.max(...lanes.map((l) => l.width));
  const forkY = translated.reduce((sum, l) => sum + l.entryY, 0) / translated.length;
  const joinX = lanesX + lanesWidth + SEG_W;
  const joinY = translated.reduce((sum, l) => sum + l.exitY, 0) / translated.length;
  const forkWires = translated.map((l, i): LayoutWire => ({ id: `${path}.fork${i}`, points: [{ x: 0, y: forkY }, { x: lanesX, y: l.entryY }] }));
  // Join wires connect each lane's ACTUAL exit (not a uniform x) to the common join point
  const joinWires = translated.map((l, i): LayoutWire => ({ id: `${path}.join${i}`, points: [{ x: lanesX + l.width, y: l.exitY }, { x: joinX, y: joinY }] }));
  const region: LayoutRegion = { id: `${path}.region`, kind, label, x: 0, y: 0, width: joinX, height };
  return {
    width: joinX,
    height,
    entryY: forkY,
    exitY: joinY,
    boxes: translated.flatMap((l) => l.boxes),
    wires: [...forkWires, ...translated.flatMap((l) => l.wires), ...joinWires],
    regions: addRegion ? [...translated.flatMap((l) => l.regions), region] : translated.flatMap((l) => l.regions),
  };
}

function layoutForkJoin(path: string, kind: RegionKind, label: string, top: Diagram, bottom: Diagram, addRegion = true): Diagram {
  return layoutLadder(path, kind, label, [top, bottom], addRegion);
}

// ── Graph walk context ────────────────────────────────────────────────────────

export interface FoldCtx {
  nodes: Record<string, WiringNode>;
  seen: Set<string>;
  insideLoop: boolean;
}

// Find the join point of two branches: the first node that both arms reach.
// Returns the join-point name (the node where both paths reconverge).
function findJoinPoint(
  thenStart: string,
  elseStart: string,
  ctx: FoldCtx,
): string {
  // Collect all reachable names from the then-arm (bounded walk)
  const thenReachable = new Set<string>();
  const queue = [thenStart];
  for (let steps = 0; steps < 500 && queue.length > 0; steps++) {
    const name = queue.pop()!;
    if (thenReachable.has(name)) continue;
    thenReachable.add(name);
    const node = ctx.nodes[name];
    if (!node) continue;
    if (node.tag === "WireReturn") continue;
    if (node.tag === "WireBranch") {
      queue.push(node.then, node.else);
    } else {
      queue.push(node.next);
    }
  }
  // Walk the else-arm until we hit a node in thenReachable
  const visited = new Set<string>();
  const equeue = [elseStart];
  for (let steps = 0; steps < 500 && equeue.length > 0; steps++) {
    const name = equeue.pop()!;
    if (visited.has(name)) continue;
    visited.add(name);
    if (thenReachable.has(name)) return name;
    const node = ctx.nodes[name];
    if (!node) return name;
    if (node.tag === "WireReturn") return name;
    if (node.tag === "WireBranch") {
      equeue.push(node.then, node.else);
    } else {
      equeue.push(node.next);
    }
  }
  return elseStart;
}

// ── Main graph walk ───────────────────────────────────────────────────────────

// Collect a chain of elseif-style branches: WireCond → WireBranch where the
// else-arm is another WireCond → WireBranch, etc. Returns the collected
// clauses and the final else-arm's entry name.
function collectBranchChain(
  entryName: string,
  ctx: FoldCtx,
): { clauses: { cond: Expr; thenName: string }[]; elseName: string } {
  const clauses: { cond: Expr; thenName: string }[] = [];
  let currentName = entryName;
  for (;;) {
    const node = ctx.nodes[currentName];
    if (!node || node.tag !== "WireCond") return { clauses, elseName: currentName };
    const condExpr = node.expr;
    const branchName = node.next;
    const branchNode = ctx.nodes[branchName];
    if (!branchNode || branchNode.tag !== "WireBranch") return { clauses, elseName: currentName };
    clauses.push({ cond: condExpr, thenName: branchNode.then });
    currentName = branchNode.else;
  }
}

function walkNode(name: string, path: string, ctx: FoldCtx, joinTarget?: string): Diagram {
  // If this is the join point of a branch, render as wire-only (the join point
  // is rendered separately after both arms merge).
  if (joinTarget !== undefined && name === joinTarget) return wireOnly(path);

  // Already rendered — back-edge or shared tail
  if (ctx.seen.has(name)) {
    const node = ctx.nodes[name];
    if (node && node.tag === "WireNop") {
      // Back-edge to loop header — render as feedback wire
      return leafBox(path, "continue-cap", `loop-back`);
    }
    return leafBox(path, "jump", `\u21a9 ${name}`);
  }
  ctx.seen.add(name);

  const node = ctx.nodes[name];
  if (!node) return wireOnly(path);

  switch (node.tag) {
  case "WireReturn":
    return leafBox(path, "return", "return");

  case "WireNop": {
    // Loop header — walk the body
    const bodyD = walkNode(node.next, `${path}.body`, { ...ctx, insideLoop: true });
    // Wrap in loop region with feedback wires from continue-cap boxes
    const bodyT = translate(bodyD, REGION_PAD, REGION_PAD);
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

  case "WireAssign": {
    const box = leafBox(path, "assign", `${node.var} := ${prettyExpr(node.rhs)}`);
    const succD = walkNode(node.next, `${path}.next`, ctx);
    return composeH(path, box, succD);
  }

  case "WireCond": {
    // Collect elseif chain (WireCond → WireBranch → WireCond → ...)
    const chain = collectBranchChain(name, ctx);
    if (chain.clauses.length >= 2) {
      // ElseIf/choose ladder — render as flat ladder
      const rows = chain.clauses.map((clause, i) => {
        const condD = leafBox(`${path}.clause${i}.cond`, "cond", prettyExpr(clause.cond));
        const thenCtx = { ...ctx, seen: new Set(ctx.seen) };
        const bodyD = walkNode(clause.thenName, `${path}.clause${i}.body`, thenCtx);
        for (const s of thenCtx.seen) ctx.seen.add(s);
        return composeH(`${path}.clause${i}`, condD, bodyD);
      });
      const elseCtx = { ...ctx, seen: new Set(ctx.seen) };
      const elseD = walkNode(chain.elseName, `${path}.else`, elseCtx);
      for (const s of elseCtx.seen) ctx.seen.add(s);
      return layoutLadder(path, "if", "if/elseif", [...rows, elseD]);
    }
    if (chain.clauses.length === 1) {
      // Single if/else — render as cond + fork/join
      const clause = chain.clauses[0]!;
      const condD = leafBox(`${path}.cond`, "cond", prettyExpr(clause.cond));
      // Find join point — the node where both arms reconverge
      const joinName = findJoinPoint(clause.thenName, chain.elseName, ctx);
      // Walk then-arm up to join point (joinTarget makes it stop with wire-only)
      const thenCtx = { ...ctx, seen: new Set(ctx.seen) };
      const thenD = walkNode(clause.thenName, `${path}.then`, thenCtx, joinName);
      for (const s of thenCtx.seen) ctx.seen.add(s);
      // Walk else-arm up to join point
      const elseCtx = { ...ctx, seen: new Set(ctx.seen) };
      const elseD = walkNode(chain.elseName, `${path}.else`, elseCtx, joinName);
      for (const s of elseCtx.seen) ctx.seen.add(s);
      // Render the join point node separately
      const joinD = walkNode(joinName, `${path}.join`, ctx);
      // Fork/join: both arms → join point
      const forkJoinRaw = layoutForkJoin(path, "if", "if", thenD, elseD, false);
      // Append the join point after the fork/join
      const forkJoin = composeH(`${path}.forkjoin`, forkJoinRaw, joinD);
      const combined = composeH(path, condD, forkJoin);
      const region: LayoutRegion = { id: `${path}.if-region`, kind: "if", label: "if", x: 0, y: 0, width: combined.width, height: combined.height };
      return { ...combined, regions: [...combined.regions, region] };
    }
    // No chain — just a bare WireCond (shouldn't happen in practice)
    const box = leafBox(path, "cond", prettyExpr(node.expr));
    const succD = walkNode(node.next, `${path}.next`, ctx);
    return composeH(path, box, succD);
  }

  case "WireBranch": {
    // Standalone WireBranch (not preceded by WireCond) — render as fork/join
    const joinName = findJoinPoint(node.then, node.else, ctx);
    const thenCtx = { ...ctx, seen: new Set(ctx.seen) };
    const thenD = walkNode(node.then, `${path}.then`, thenCtx, joinName);
    for (const s of thenCtx.seen) ctx.seen.add(s);
    const elseCtx = { ...ctx, seen: new Set(ctx.seen) };
    const elseD = walkNode(node.else, `${path}.else`, elseCtx, joinName);
    for (const s of elseCtx.seen) ctx.seen.add(s);
    const joinD = walkNode(joinName, `${path}.join`, ctx);
    const forkJoinRaw = layoutForkJoin(path, "fork", "fork", thenD, elseD);
    return composeH(`${path}.forkjoin`, forkJoinRaw, joinD);
  }

  case "WireCall": {
    const label = `${node.callee}(${prettyExprArgs(node.args)})`;
    const box = leafBox(path, "call", label);
    const succD = walkNode(node.next, `${path}.next`, ctx);
    return composeH(path, box, succD);
  }

  case "WireSuspend": {
    const label = `${node.effect}(${prettyExprArgs(node.args)})`;
    const box = leafBox(path, "suspend", label);
    const succD = walkNode(node.next, `${path}.next`, ctx);
    return composeH(path, box, succD);
  }
  }
}

// ── Entry point ───────────────────────────────────────────────────────────────

export function layoutWiring(graph: WiringGraph): WiringLayout {
  const ctx: FoldCtx = { nodes: graph.nodes, seen: new Set(), insideLoop: false };
  const d = walkNode(graph.entry, "0", ctx);
  return { boxes: d.boxes, wires: d.wires, regions: d.regions, width: d.width, height: d.height };
}
