// interpreter.ts — PB AST interpreter.

import type { BodyStmt, Expr, Located } from "../types/ast.generated.js";
import { PB_BUILTINS } from "./runtime.js";

export interface DWRow {
  [column: string]: unknown;
}

export type ProcEntry = { name: string; owner: string; body: Located<BodyStmt>[] };

export interface AstData {
  typeBlocks: { decl: { ancestor: string; name: string; within: string | null }; body: Located<BodyStmt>[] }[];
  events: ProcEntry[];
  functions?: ProcEntry[];
  ancestorName?: string;
  ancestorEvents?: ProcEntry[];
  ancestorFunctions?: ProcEntry[];
}

export interface InterpreterState {
  variables: Record<string, unknown>;
  controlValues: Record<string, unknown>;
}

export class PBInterpreter {
  private _variables = new Map<string, unknown>();
  private _controlValues = new Map<string, unknown>();
  private _eventIndex = new Map<string, { name: string; owner: string; body: Located<BodyStmt>[] }>();
  private _funcIndex = new Map<string, { name: string; owner: string; body: Located<BodyStmt>[] }>();
  ast: AstData | null = null;

  setAst(ast: AstData): void {
    this.ast = ast;
    this._eventIndex.clear();
    this._funcIndex.clear();
    for (const e of ast.events) {
      this._eventIndex.set(`${e.owner}::${e.name}`, e);
    }
    for (const f of ast.functions ?? []) {
      this._funcIndex.set(`${f.owner}::${f.name}`, f);
    }
  }

  async executeEvent(owner: string, event: string): Promise<void> {
    const handler = this._eventIndex.get(`${owner}::${event}`);
    if (handler) await this._walkStatements(handler.body);
  }

  getState(): InterpreterState {
    return {
      variables: Object.fromEntries(this._variables),
      controlValues: Object.fromEntries(this._controlValues),
    };
  }

  private async _walkStatements(stmts: Located<BodyStmt>[]): Promise<void> {
    for (const stmt of stmts) {
      await this._walkNode(stmt.node);
    }
  }

  private async _walkNode(node: BodyStmt): Promise<unknown> {
    switch (node.tag) {
      case "BsAssign": {
        const [lhs, rhs] = node.contents;
        const varName = lhs.segments[0]?.name;
        if (varName) this._variables.set(varName, this._evalExpr(rhs));
        return undefined;
      }
      case "BsIf": {
        const { cond, then, elseIfs, else: elseBody } = node.contents;
        if (this._evalExpr(cond)) {
          await this._walkStatements(then);
          return undefined;
        }
        for (const ei of elseIfs) {
          if (this._evalExpr(ei.cond)) {
            await this._walkStatements(ei.body);
            return undefined;
          }
        }
        if (elseBody) await this._walkStatements(elseBody);
        return undefined;
      }
      case "BsCall": {
        this._evalExpr(node.contents);
        return undefined;
      }
      case "BsReturn":
        return node.contents ? this._evalExpr(node.contents) : undefined;
      case "BsRaw":
        return undefined;
      case "BsLocalVar": {
        if (node.init) {
          const val = this._evalExpr(node.init);
          this._variables.set(node.name, val);
        }
        return undefined;
      }
      case "BsFor": {
        const fv = node.contents;
        const varName = fv.var?.segments[0]?.name;
        if (!varName) return undefined;
        const from = Number(this._evalExpr(fv.from));
        const to = Number(this._evalExpr(fv.to));
        const step = fv.step ? Number(this._evalExpr(fv.step)) : 1;
        if (step === 0) return undefined;
        for (let i = from; step > 0 ? i <= to : i >= to; i += step) {
          this._variables.set(varName, i);
          await this._walkStatements(fv.body);
        }
        return undefined;
      }
      case "BsDo": {
        const dv = node.contents;
        if (dv.cond) {
          const isWhile = dv.cond.tag === "DoWhile";
          const condExpr = dv.cond.contents;
          do {
            await this._walkStatements(dv.body);
          } while (
            isWhile ? this._evalExpr(condExpr) : !this._evalExpr(condExpr)
          );
        } else {
          await this._walkStatements(dv.body);
        }
        return undefined;
      }
      case "BsChoose": {
        const cv = node.contents;
        const value = this._evalExpr(cv.expr);
        for (const clause of cv.clauses) {
          if (clause.expr === null) {
            await this._walkStatements(clause.body);
            return undefined;
          }
          const caseValue = this._evalTokenArg(clause.expr);
          if (value === caseValue || String(value) === String(caseValue)) {
            await this._walkStatements(clause.body);
            return undefined;
          }
        }
        return undefined;
      }
      case "BsExit":
        return undefined;
      case "BsContinue":
        return undefined;
      case "BsDestroy":
        return undefined;
      case "BsPbCall":
        return undefined;
      case "BsAugAssign":
        return undefined;
      case "BsInc":
        return undefined;
      case "BsDec":
        return undefined;
      case "BsAssignExpr": {
        const [, rhs] = node.contents;
        return this._evalExpr(rhs);
      }
    }
  }

  private _evalExpr(expr: Expr): unknown {
    switch (expr.tag) {
      case "ExBool":
        return expr.contents;
      case "ExInt":
        return parseInt(expr.contents, 10);
      case "ExReal":
        return parseFloat(expr.contents);
      case "ExStr":
        return expr.contents;
      case "ExDate":
        return expr.contents;
      case "ExTime":
        return expr.contents;
      case "ExNull":
        return null;
      case "ExEnum":
        return expr.contents;
      case "ExLvalue": {
        const name = expr.contents.segments[0]?.name;
        return name ? this._variables.get(name) : undefined;
      }
      case "ExCall": {
        const calleeName = expr.callee.segments.map((s) => s.name).join(".");
        // ExCall.args are string[][] (raw tokens); parse common literals
        const args = expr.args.map((a) => this._evalTokenArg(a));
        const fn = PB_BUILTINS[calleeName];
        if (fn) return fn(...args);
        return undefined;
      }
      case "ExBinOp":
        return this._evalBinOp(expr.lhs, expr.op, expr.rhs);
      case "ExNot":
        return !this._evalExpr(expr.contents);
      case "ExNeg":
        return -(this._evalExpr(expr.contents) as number);
      case "ExMethodCall":
        return undefined;
      case "ExDispatch":
        return undefined;
      case "ExCreate":
        return undefined;
      case "ExCreateUsing":
        return undefined;
      case "ExArray":
        return undefined;
      case "ExHostVar":
        return undefined;
      case "ExRaw":
        return undefined;
    }
  }

  // Parse raw token arrays (from ExCall.args) into JS values.
  private _evalTokenArg(tokens: string[]): unknown {
    if (tokens.length === 0) return undefined;
    const raw = tokens.join("").trim();
    if (raw === "null") return null;
    if (raw === "true") return true;
    if (raw === "false") return false;
    // String literal (surrounded by quotes)
    if (raw.startsWith('"') && raw.endsWith('"')) return raw.slice(1, -1);
    // Integer
    if (/^-?\d+$/.test(raw)) return parseInt(raw, 10);
    // Real
    if (/^-?\d+\.\d+$/.test(raw)) return parseFloat(raw);
    // Variable reference — look up in scope
    if (/^[a-zA-Z_]/.test(raw)) {
      const dotIdx = raw.indexOf(".");
      const baseName = dotIdx >= 0 ? raw.slice(0, dotIdx) : raw;
      return this._variables.get(baseName);
    }
    return raw;
  }

  private _evalBinOp(lhs: Expr, op: string, rhs: Expr): unknown {
    const l = this._evalExpr(lhs);
    const r = this._evalExpr(rhs);
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
      case "BopAnd": return (l as boolean) && (r as boolean);
      case "BopOr":  return (l as boolean) || (r as boolean);
      case "BopXor": return !!(l as boolean) !== !!(r as boolean);
      default: return undefined;
    }
  }
}
