// interpreter/instr/expr.ts — Expression evaluator for the InstrGraph compiler and runner.

import type { Expr } from "../types/ast.js";
import { PB_BUILTINS } from "../runtime.js";
import { type VarEnv, readVar } from "./var-env.js";

export function evalExpr(env: VarEnv, expr: Expr): unknown {
  switch (expr.tag) {
    case "ExBool":   return expr.contents;
    case "ExInt":    return parseInt(expr.contents, 10);
    case "ExReal":   return parseFloat(expr.contents);
    case "ExStr":    return expr.contents;
    case "ExDate":   return expr.contents;
    case "ExTime":   return expr.contents;
    case "ExNull":   return null;
    case "ExEnum":   return expr.contents;
    case "ExLvalue": {
      const name = expr.contents.segments[0]?.name;
      return name ? readVar(env, name) : undefined;
    }
    case "ExCall": {
      const callee = expr.callee.segments.map((s) => s.name).join(".");
      const args = expr.args.map((a) => evalExpr(env, a));
      const fn = PB_BUILTINS[callee];
      return fn ? fn(...args) : undefined;
    }
    case "ExBinOp":
      return evalBinOp(evalExpr(env, expr.lhs), expr.op, evalExpr(env, expr.rhs));
    case "ExNot":    return !evalExpr(env, expr.contents);
    case "ExNeg":    return -(evalExpr(env, expr.contents) as number);
    default:         return undefined;
  }
}

function evalBinOp(l: unknown, op: string, r: unknown): unknown {
  switch (op) {
    case "BopAdd": return (l as number) + (r as number);
    case "BopSub": return (l as number) - (r as number);
    case "BopMul": return (l as number) * (r as number);
    case "BopDiv": return (l as number) / (r as number);
    case "BopPow": return Math.pow(l as number, r as number);
    case "BopEq":  return l === r;
    case "BopNe":  return l !== r;
    case "BopLt":  return (l as number) < (r as number);
    case "BopGt":  return (l as number) > (r as number);
    case "BopLe":  return (l as number) <= (r as number);
    case "BopGe":  return (l as number) >= (r as number);
    case "BopAnd": return !!(l) && !!(r);
    case "BopOr":  return !!(l) || !!(r);
    case "BopXor": return !!(l) !== !!(r);
    default: return undefined;
  }
}
