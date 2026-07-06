// interpreter/instr/runner.ts — Step driver for InstrGraphs.

import { Effect } from "@pb/core";
import { PB_BUILTINS } from "../runtime.js";
import type { InstrEnv, InstrGraph } from "./types.js";
import { type VarEnv, writeVar } from "./var-env.js";
import { evalExpr } from "./expr.js";

export type { InstrEnv } from "./types.js";

export type InstrResumeAction =
  | { tag: "instr-resume"; pc: number; var: string | null; value: unknown }
  // Plan 115 item 2: a InstrCallProc node requests dispatch to a named callee
  // body (CALL ancestor::event or TriggerEvent). The reducer pushes the
  // current graph onto a call stack and resumes at resumePc when the callee
  // completes. Unlike instr-resume, this carries no SQL value.
  | { tag: "instr-dispatch"; callee: string; args: unknown[]; resumePc: number };

/**
 * Execute a InstrGraph from pc, returning an Effect if a suspension point is hit,
 * or null if execution completed.
 */
export function step(
  graph: InstrGraph,
  pc: number,
  varEnv: VarEnv,
  env: InstrEnv,
): Effect<InstrResumeAction> | null {
  if (pc < 0 || pc >= graph.nodes.length) return null;

  const node = graph.nodes[pc]!;
  switch (node.kind) {
    case "return":
      return null;

    case "assign":
      writeVar(varEnv, node.var, evalExpr(varEnv, node.rhs));
      return step(graph, node.next, varEnv, env);

    case "branch":
      return evalExpr(varEnv, node.cond)
        ? step(graph, node.then_, varEnv, env)
        : step(graph, node.else_, varEnv, env);

    case "goto":
      return step(graph, node.target, varEnv, env);

    case "call": {
      const args = node.args.map((a) => evalExpr(varEnv, a));
      // DW methods that don't suspend: no-op and continue.
      const dotIdx = node.callee.lastIndexOf(".");
      if (dotIdx >= 0) {
        const methodName = node.callee.slice(dotIdx + 1).toLowerCase();
        if (["settransobject", "getchild", "setfilter", "filter", "sort", "setsort"].includes(methodName)) {
          return step(graph, node.next, varEnv, env);
        }
      }
      const fn = PB_BUILTINS[node.callee];
      if (fn) {
        if (node.result) writeVar(varEnv, node.result, fn(...args));
      }
      return step(graph, node.next, varEnv, env);
    }

    case "suspend": {
      const args = node.args.map((a) => evalExpr(varEnv, a));
      const effect = dispatchSuspend(node.effect, args, env);
      if (!effect) return step(graph, node.continuation, varEnv, env);
      return effect.map((result): InstrResumeAction => ({
        tag: "instr-resume",
        pc: node.continuation,
        var: node.var ?? null,
        value: result,
      }));
    }

    case "nop":
      return step(graph, node.next, varEnv, env);

    case "callproc": {
      // Plan 115 item 2: emit a instr-dispatch effect. The reducer resolves the
      // callee body and either runs it (pushing the current graph to resume at
      // node.next) or skips to node.next if no body is found.
      const args = node.args.map((a) => evalExpr(varEnv, a));
      return Effect.send<InstrResumeAction>({
        tag: "instr-dispatch",
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
  env: InstrEnv,
): Effect<unknown> | null {
  if (effect.startsWith("retrieve:")) {
    const effectBody = effect.slice("retrieve:".length);
    if (effectBody.startsWith("child_")) {
      // Format: "retrieve:child_<col>:<dwCtrl>" — compiler encodes parent DW control.
      const sep = effectBody.indexOf(":", "child_".length);
      const dwCtrl = sep >= 0 ? effectBody.slice(sep + 1) : null;
      if (!dwCtrl) return null;
      const sql = env.dwNameToSql?.(dwCtrl) ?? null;
      if (!sql) return null;
      return env.executeSql(sql, args).map((r) => ({ dwName: dwCtrl, rows: r.rows }));
    }
    // Regular DW retrieve: "retrieve:<dwCtrl>"
    const dwCtrl = effectBody;
    const sql = env.dwNameToSql?.(dwCtrl) ?? null;
    if (!sql) return null;
    return env.executeSql(sql, args).map((r) => ({ dwName: dwCtrl, rows: r.rows }));
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
