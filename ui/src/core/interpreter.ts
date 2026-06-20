// interpreter.ts — Minimal PB AST interpreter (spike).

import type { BodyStmt, Expr, Located } from "../types/ast.generated.js";

export interface AstData {
  typeBlocks: { decl: { ancestor: string; name: string; within: string | null }; body: Located<BodyStmt>[] }[];
  events: { name: string; owner: string; body: Located<BodyStmt>[] }[];
}

export interface InterpreterState {
  variables: Record<string, unknown>;
  controlValues: Record<string, unknown>;
}

export class PBInterpreter {
  private _variables = new Map<string, unknown>();
  private _controlValues = new Map<string, unknown>();
  ast: AstData | null = null;

  setAst(ast: AstData): void {
    this.ast = ast;
  }

  async executeEvent(owner: string, event: string): Promise<void> {
    const handler = this.ast?.events.find(
      (e) => e.name === event && e.owner === owner,
    );
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
        const callee = node.contents.tag === "ExCall" ? node.contents.callee : null;
        const name = callee?.segments.map((s) => s.name).join(".") ?? "";
        if (name === "MessageBox") return undefined;
        return undefined;
      }
      case "BsReturn":
        return node.contents ? this._evalExpr(node.contents) : undefined;
      case "BsRaw":
        return undefined;
      case "BsLocalVar":
        return undefined;
      case "BsFor":
        return undefined;
      case "BsDo":
        return undefined;
      case "BsChoose":
        return undefined;
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
        if (calleeName === "MessageBox") return undefined;
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
