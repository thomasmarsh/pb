// core/cps/load.ts — Deserialise Haskell-generated CPS graph JSON.
//
// The Haskell CpsCompile module produces JSON with:
//   - "tag" discriminator (e.g. "CpsAssign") mapped to TypeScript kind
//   - brThenPc/brElsePc → then_/else_ (avoid TS keyword collision)
//   - sourceMap as [[pc, line], ...] → Map<number, number>

import type { CpsGraph, CpsNode } from "./types.js";
import type { Expr } from "../../types/ast.generated.js";

// Raw JSON shape from Haskell serialisation.
type RawCpsNode = Record<string, unknown>;

interface RawCpsGraph {
  nodes: RawCpsNode[];
  entry: number;
  suspensionPoints: number[];
  sourceMap: [number, number][];
}

function loadNode(raw: RawCpsNode): CpsNode | null {
  const tag = raw["tag"] as string | undefined;
  switch (tag) {
    case "CpsAssign":
      return {
        kind: "assign",
        var: raw["var"] as string,
        rhs: raw["rhs"] as Expr,
        next: raw["next"] as number,
      };
    case "CpsBranch":
      return {
        kind: "branch",
        cond: raw["cond"] as Expr,
        then_: raw["thenPc"] as number,
        else_: raw["elsePc"] as number,
      };
    case "CpsGoto":
      return { kind: "goto", target: raw["target"] as number };
    case "CpsCall":
      return {
        kind: "call",
        callee: raw["callee"] as string,
        args: (raw["args"] as Expr[]) ?? [],
        result: raw["result"] as string | undefined,
        next: raw["next"] as number,
      };
    case "CpsSuspend":
      return {
        kind: "suspend",
        effect: raw["effect"] as string,
        args: (raw["args"] as Expr[]) ?? [],
        var: raw["var"] as string | undefined,
        continuation: raw["continuation"] as number,
      };
    case "CpsReturn":
      return {
        kind: "return",
        value: raw["value"] as Expr | undefined,
      };
    case "CpsNop":
      return { kind: "nop", next: raw["next"] as number };
    default:
      return null;
  }
}

export function loadCpsGraph(json: unknown): CpsGraph {
  const raw = json as RawCpsGraph;
  const nodes: CpsNode[] = (raw.nodes ?? [])
    .map(loadNode)
    .filter((n): n is CpsNode => n !== null);
  return {
    nodes,
    entry: raw.entry ?? 0,
    suspensionPoints: raw.suspensionPoints ?? [],
    sourceMap: new Map(raw.sourceMap ?? []),
  };
}
