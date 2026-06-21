// core/cps/runner.ts — Step driver for CPS graphs.

import { Effect } from "../../core/effect.js";
import { PB_BUILTINS } from "../runtime.js";
import type { CpsEnv, CpsGraph } from "./types.js";
import { evalExpr } from "./expr.js";

export type { CpsEnv } from "./types.js";

export interface CpsResumeAction {
  tag: "cps-resume";
  pc: number;
  var: string | null;
  value: unknown;
}

/**
 * Execute a CPS graph from pc, returning an Effect if a suspension point is hit,
 * or null if execution completed.
 */
export function step(
  graph: CpsGraph,
  pc: number,
  vars: Record<string, unknown>,
  env: CpsEnv,
): Effect<CpsResumeAction> | null {
  if (pc < 0 || pc >= graph.nodes.length) return null;

  const node = graph.nodes[pc]!;
  switch (node.kind) {
    case "return":
      return null;

    case "assign":
      vars[node.var] = evalExpr(vars, node.rhs);
      return step(graph, node.next, vars, env);

    case "branch":
      return evalExpr(vars, node.cond)
        ? step(graph, node.then_, vars, env)
        : step(graph, node.else_, vars, env);

    case "goto":
      return step(graph, node.target, vars, env);

    case "call": {
      const fn = PB_BUILTINS[node.callee];
      if (fn) {
        const args = node.args.map((a) => evalExpr(vars, a));
        if (node.result) vars[node.result] = fn(...args);
      }
      return step(graph, node.next, vars, env);
    }

    case "suspend": {
      const args = node.args.map((a) => evalExpr(vars, a));
      const effect = dispatchSuspend(node.effect, args, env);
      if (!effect) return step(graph, node.continuation, vars, env);
      return effect.map((result): CpsResumeAction => ({
        tag: "cps-resume",
        pc: node.continuation,
        var: node.var ?? null,
        value: result,
      }));
    }

    case "nop":
      return step(graph, node.next, vars, env);

    default:
      return null;
  }
}

function dispatchSuspend(
  effect: string,
  args: unknown[],
  env: CpsEnv,
): Effect<unknown> | null {
  switch (effect) {
    case "executeSql": {
      const sql = String(args[0] ?? "");
      const params = args.slice(1);
      return env.executeSql(sql, params).map((r) => r.rows);
    }
    case "open":
    case "opensheet": {
      const windowName = String(args[0] ?? "");
      return env.open(windowName);
    }
    default:
      return null;
  }
}
