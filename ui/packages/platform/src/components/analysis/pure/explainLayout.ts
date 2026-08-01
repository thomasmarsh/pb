// explainLayout.ts — Pure helpers over PB.Explain.Pseudocode's materialized
// JSON (Plan 222 Phase 4). Two jobs: (1) normalize each PStmt's positional
// `contents` tuple into named fields, so callers never index into it; (2)
// walk the region DAG in the same order/dedup shape as PB.Explain.Render.
// Text's collectRefs/renderRefs (compiler/src/PB/Explain/Render/Text.hs) —
// root region first, then every PRegionRef reached by recursing into
// PBranch/PLoop bodies, deduped by regionId, never recursing into a
// referenced region's own body a second time.
//
// Only formats already-structured, typed data (VarBinding/PbType/
// InferredSignature/DeclaredSig) — never unparses an Expr (Plan 222's own
// Non-Goal; PStmt's raw Expr positions stay `unknown` in api.ts).

import type {
  PStmt, Pseudocode, InferredSignature, VarBinding, PbType, EffectTag,
  Param, DeclaredSig,
} from "../../../types/api.js";

// ── Statement normalization ────────────────────────────────────────────────

export interface RegionRefInfo {
  regionId: string;
  lineRange: [number, number] | null;
  sig: InferredSignature | null;
}

export type NormalizedStmt =
  | { kind: "assign"; line: number; text: string }
  | { kind: "call"; line: number; text: string }
  | { kind: "return"; line: number; text: string }
  | { kind: "branch"; line: number; text: string; then: NormalizedStmt[]; else: NormalizedStmt[] }
  | { kind: "loop"; line: number; text: string; body: NormalizedStmt[] }
  | ({ kind: "regionRef"; text: string } & RegionRefInfo);

export function normalizeStmt(stmt: PStmt): NormalizedStmt {
  switch (stmt.tag) {
    case "PAssign":
      return { kind: "assign", line: stmt.contents[4], text: stmt.stmtText };
    case "PCall":
      return { kind: "call", line: stmt.contents[3], text: stmt.stmtText };
    case "PReturn":
      return { kind: "return", line: stmt.contents[1], text: stmt.stmtText };
    case "PBranch":
      return {
        kind: "branch",
        line: stmt.contents[3],
        text: stmt.stmtText,
        then: normalizeStmts(stmt.contents[1]),
        else: normalizeStmts(stmt.contents[2]),
      };
    case "PLoop":
      return {
        kind: "loop",
        line: stmt.contents[1],
        text: stmt.stmtText,
        body: normalizeStmts(stmt.contents[0]),
      };
    case "PRegionRef":
      return {
        kind: "regionRef",
        text: stmt.stmtText,
        regionId: stmt.contents[0],
        lineRange: stmt.contents[1],
        sig: stmt.contents[2],
      };
  }
}

export function normalizeStmts(stmts: PStmt[]): NormalizedStmt[] {
  return stmts.map(normalizeStmt);
}

// A hovered/clicked statement's own source line(s) — a region ref highlights
// its whole cut-out range; every other statement kind highlights its single
// line (a PBranch/PLoop's own header line, not its body's lines — those are
// separately hoverable as their own list entries).
export function sourceLinesForStmt(stmt: NormalizedStmt): Set<number> {
  if (stmt.kind === "regionRef") {
    if (!stmt.lineRange) return new Set();
    const [start, end] = stmt.lineRange;
    const lines = new Set<number>();
    for (let l = start; l <= end; l++) lines.add(l);
    return lines;
  }
  return new Set([stmt.line]);
}

// ── Region DAG walk ─────────────────────────────────────────────────────────

export interface RegionCard {
  regionId: string;
  isRoot: boolean;
  lineRange: [number, number] | null;
  sig: InferredSignature | null;
  stmts: NormalizedStmt[];
}

// Every PRegionRef reachable from a statement list, recursing into branch/
// loop bodies but not into a referenced region's own body — mirrors
// Render/Text.hs's collectRefs exactly.
function collectRegionRefs(stmts: NormalizedStmt[]): RegionRefInfo[] {
  const out: RegionRefInfo[] = [];
  for (const s of stmts) {
    if (s.kind === "regionRef") {
      out.push({ regionId: s.regionId, lineRange: s.lineRange, sig: s.sig });
    } else if (s.kind === "branch") {
      out.push(...collectRegionRefs(s.then), ...collectRegionRefs(s.else));
    } else if (s.kind === "loop") {
      out.push(...collectRegionRefs(s.body));
    }
  }
  return out;
}

export function collectRegionCards(pc: Pseudocode): RegionCard[] {
  const rootStmts = normalizeStmts(pc.regions[pc.rootRegion] ?? []);
  const cards: RegionCard[] = [
    { regionId: pc.rootRegion, isRoot: true, lineRange: null, sig: pc.rootSig, stmts: rootStmts },
  ];
  const seen = new Set<string>([pc.rootRegion]);
  const queue: RegionRefInfo[] = [...collectRegionRefs(rootStmts)];

  while (queue.length > 0) {
    const ref = queue.shift()!;
    if (seen.has(ref.regionId)) continue;
    seen.add(ref.regionId);
    const stmts = normalizeStmts(pc.regions[ref.regionId] ?? []);
    cards.push({ regionId: ref.regionId, isRoot: false, lineRange: ref.lineRange, sig: ref.sig, stmts });
    queue.push(...collectRegionRefs(stmts));
  }

  return cards;
}

// ── Formatting (structured data only — never an Expr) ──────────────────────

export function formatPbType(t: PbType): string {
  switch (t.tag) {
    case "PtPrimitive": return t.contents;
    case "PtUserDefined": return t.contents;
    case "PtAny": return "any";
    case "PtDecimalPrec": return `decimal{${t.contents}}`;
  }
}

export function formatVarBinding(vb: VarBinding): string {
  return vb.type ? `${vb.name}: ${formatPbType(vb.type)}` : vb.name;
}

export function formatEffects(effects: EffectTag[]): string {
  if (effects.length === 0) return "pure";
  return [...effects].sort().join(", ");
}

export function formatInferredSignature(name: string, sig: InferredSignature): string {
  const ins = sig.inputs.map(formatVarBinding).join(", ");
  const outs = sig.outputs.map(formatVarBinding).join(", ");
  return `${name}(${ins}) -> (${outs})  [${formatEffects(sig.effects)}]`;
}

export function regionDisplayLabel(regionId: string, lineRange: [number, number] | null): string {
  return lineRange ? `region_${lineRange[0]}` : regionId;
}

// A region-ref rendered as a call site (name + input arg names) rather than
// the backend's "-> region@N" arrow text, so it reads like the function call
// it stands in for; clicking it still jumps to that region's own card.
export function formatRegionCallLabel(
  regionId: string,
  lineRange: [number, number] | null,
  sig: InferredSignature | null,
): string {
  const args = sig ? sig.inputs.map((v) => v.name).join(", ") : "";
  return `${regionDisplayLabel(regionId, lineRange)}(${args})`;
}

export function formatParams(params: Param[]): string {
  return params.map((p) => [...p.mods, p.type, p.name].join(" ")).join(", ");
}

export function formatDeclaredSig(d: DeclaredSig): string {
  if ("Left" in d) {
    const f = d.Left;
    return `${f.name}(${formatParams(f.params)}): ${f.returnType}`;
  }
  const s = d.Right;
  return `${s.name}(${formatParams(s.params)})`;
}
