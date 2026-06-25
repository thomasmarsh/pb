// core/cps/types.ts — CPS graph data types for the composable step machine.

import type { Effect } from "../../core/effect.js";
import type { SQLResult } from "../../core/dw-queries.js";
import type { Expr } from "../../types/ast.js";

/** A flat instruction in the CPS graph. No nested control flow. */
export type CpsNode =
  | { kind: "assign"; var: string; rhs: Expr; next: number }
  | { kind: "branch"; cond: Expr; then_: number; else_: number }
  | { kind: "goto"; target: number }
  | { kind: "call"; callee: string; args: Expr[]; result?: string; next: number }
  | { kind: "suspend"; effect: string; args: Expr[]; var?: string; continuation: number }
  | { kind: "return"; value?: Expr }
  | { kind: "nop"; next: number }
  // Plan 115 item 2: dispatch a CALL ancestor::event / TriggerEvent to a body
  // found via the AST. Execution suspends the current graph on a call stack and
  // resumes at cpNext once the callee body completes (or is skipped if not found).
  | { kind: "callproc"; callee: string; args: Expr[]; next: number };

export interface CpsGraph {
  nodes: CpsNode[];
  entry: number;
  suspensionPoints: number[];
  sourceMap: Map<number, number>;
}

export interface CpsEnv {
  executeSql(sql: string, params: unknown[]): Effect<SQLResult>;
  open(windowName: string): Effect<unknown>;
  /** Resolve a DataWindow control name to its SQL query. Optional — only provided in runtime context. */
  dwNameToSql?: (dwName: string) => string | null;
}
