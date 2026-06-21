// core/cps/runner.ts — Step driver for CPS graphs.

import { Effect } from "../../core/effect.js";
import { PB_BUILTINS } from "../runtime.js";
import type { CpsEnv, CpsGraph } from "./types.js";
import { evalExpr } from "./expr.js";

export type { CpsEnv } from "./types.js";

export type CpsResumeAction =
  | { tag: "cps-resume"; pc: number; var: string | null; value: unknown }
  // Plan 115 item 2: a CpsCallProc node requests dispatch to a named callee
  // body (CALL ancestor::event or TriggerEvent). The reducer pushes the
  // current graph onto a call stack and resumes at resumePc when the callee
  // completes. Unlike cps-resume, this carries no SQL value.
  | { tag: "cps-dispatch"; callee: string; args: unknown[]; resumePc: number };

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

    case "callproc": {
      // Plan 115 item 2: emit a cps-dispatch effect. The reducer resolves the
      // callee body and either runs it (pushing the current graph to resume at
      // node.next) or skips to node.next if no body is found.
      const args = node.args.map((a) => evalExpr(vars, a));
      return Effect.send<CpsResumeAction>({
        tag: "cps-dispatch",
        callee: node.callee,
        args,
        resumePc: node.next,
      });
    }

    default:
      return null;
  }
}

function dispatchSuspend(
  effect: string,
  args: unknown[],
  env: CpsEnv,
): Effect<unknown> | null {
  if (effect.startsWith("retrieve:")) {
    const dwName = effect.slice("retrieve:".length);
    const sql = env.dwNameToSql?.(dwName) ?? null;
    if (!sql) return null;
    return env.executeSql(sql, args).map((r) => ({ dwName, rows: r.rows }));
  }
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
