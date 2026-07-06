// interpreter/instr/load.ts — Deserialise Haskell-generated InstrGraph JSON.
//
// The Haskell InstrGraph module produces JSON with:
//   - "tag" discriminator (e.g. "InstrAssign") mapped to TypeScript kind
//   - brThenPc/brElsePc → then_/else_ (avoid TS keyword collision)
//   - sourceMap as [[pc, line], ...] → Map<number, number>

import type { InstrGraph, InstrNode } from "./types.js";
import type { Expr } from "../types/ast.js";

// Raw JSON shape from Haskell serialisation.
type RawInstrNode = Record<string, unknown>;

interface RawInstrGraph {
  nodes: RawInstrNode[];
  entry: number;
  suspensionPoints: number[];
  sourceMap: [number, number][];
}

function loadNode(raw: RawInstrNode): InstrNode | null {
  const tag = raw["tag"] as string | undefined;
  switch (tag) {
    case "InstrAssign":
      return {
        kind: "assign",
        var: raw["var"] as string,
        rhs: raw["rhs"] as Expr,
        next: raw["next"] as number,
      };
    case "InstrBranch":
      return {
        kind: "branch",
        cond: raw["cond"] as Expr,
        then_: raw["thenPc"] as number,
        else_: raw["elsePc"] as number,
      };
    case "InstrGoto":
      return { kind: "goto", target: raw["target"] as number };
    case "InstrCall":
      return {
        kind: "call",
        callee: raw["callee"] as string,
        args: (raw["args"] as Expr[]) ?? [],
        result: raw["result"] as string | undefined,
        next: raw["next"] as number,
      };
    case "InstrSuspend":
      return {
        kind: "suspend",
        effect: raw["effect"] as string,
        args: (raw["args"] as Expr[]) ?? [],
        var: raw["var"] as string | undefined,
        continuation: raw["continuation"] as number,
      };
    case "InstrReturn":
      return {
        kind: "return",
        value: raw["value"] as Expr | undefined,
      };
    case "InstrNop":
      return { kind: "nop", next: raw["next"] as number };
    case "InstrCallProc":
      return {
        kind: "callproc",
        callee: raw["callee"] as string,
        args: (raw["args"] as Expr[]) ?? [],
        next: raw["next"] as number,
      };
    default:
      return null;
  }
}

export function loadInstrGraph(json: unknown): InstrGraph {
  const raw = json as RawInstrGraph;
  const nodes: InstrNode[] = (raw.nodes ?? [])
    .map(loadNode)
    .filter((n): n is InstrNode => n !== null);
  return {
    nodes,
    entry: raw.entry ?? 0,
    suspensionPoints: raw.suspensionPoints ?? [],
    sourceMap: new Map(raw.sourceMap ?? []),
  };
}
