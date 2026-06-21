// core/cps/compile.ts — Compile a PB procedure body into a flat CPS graph.

import type { BodyStmt, Expr, Located } from "../../types/ast.generated.js";
import type { CpsGraph, CpsNode } from "./types.js";

// ── Side-effect classification ────────────────────────────────────────────────

function classifyCall(expr: Expr): "pure" | "suspend" {
  if (expr.tag === "ExCall") {
    const segs = expr.callee.segments;
    const name = segs.map((s) => s.name).join(".");
    // dw.retrieve() — SQL suspension
    if (segs.length === 2 && segs[1]!.name.toLowerCase() === "retrieve") return "suspend";
    if (name === "fn_retrievechild") return "suspend";
    // open() / opensheet() — window suspension
    if (name.toLowerCase() === "open" || name.toLowerCase() === "opensheet") return "suspend";
    return "pure";
  }
  if (expr.tag === "ExMethodCall") {
    if (expr.method.toLowerCase() === "retrieve") return "suspend";
    return "pure";
  }
  return "pure";
}

function calleeName(expr: Expr): string {
  if (expr.tag === "ExCall") return expr.callee.segments.map((s) => s.name).join(".");
  if (expr.tag === "ExMethodCall") {
    const receiver = expr.receiver.tag === "ExLvalue"
      ? expr.receiver.contents.segments.map((s) => s.name).join(".")
      : "?";
    return `${receiver}.${expr.method}`;
  }
  return "?";
}

// ── Compiler ──────────────────────────────────────────────────────────────────

class GraphBuilder {
  nodes: CpsNode[] = [];
  entry = 0;
  sourceMap = new Map<number, number>();
  suspensionPoints: number[] = [];

  emit(node: CpsNode, sourceLine?: number): number {
    const pc = this.nodes.length;
    this.nodes.push(node);
    if (sourceLine !== undefined) this.sourceMap.set(pc, sourceLine);
    if (node.kind === "suspend") this.suspensionPoints.push(pc);
    return pc;
  }

  patchNext(pc: number, next: number): void {
    const node = this.nodes[pc]!;
    if (node.kind === "assign") (node as { next: number }).next = next;
    else if (node.kind === "call") (node as { next: number }).next = next;
    else if (node.kind === "nop") (node as { next: number }).next = next;
  }

  build(): CpsGraph {
    return {
      nodes: this.nodes,
      entry: this.entry,
      suspensionPoints: this.suspensionPoints,
      sourceMap: this.sourceMap,
    };
  }
}

export function compileFunction(body: Located<BodyStmt>[]): CpsGraph {
  const b = new GraphBuilder();

  // Emit return node first so body statements can fall through to it.
  const returnPc = b.emit({ kind: "return" });

  if (body.length === 0) {
    return b.build();
  }

  const entryPc = compileStmts(body, returnPc, b);
  // Patch entry to point to the first real instruction
  b.entry = entryPc;
  return b.build();
}

function compileStmts(
  stmts: Located<BodyStmt>[],
  fallthrough: number,
  b: GraphBuilder,
): number {
  if (stmts.length === 0) return fallthrough;

  let nextPc = fallthrough;
  // Compile in reverse so fallthrough links work
  for (let i = stmts.length - 1; i >= 0; i--) {
    nextPc = compileStmt(stmts[i]!, nextPc, b);
  }
  return nextPc;
}

function compileStmt(
  stmt: Located<BodyStmt>,
  fallthrough: number,
  b: GraphBuilder,
): number {
  const node = stmt.node;
  const line = stmt.line;

  switch (node.tag) {
    case "BsLocalVar": {
      if (node.init) {
        const pc = b.emit({ kind: "assign", var: node.name, rhs: node.init, next: fallthrough }, line);
        return pc;
      }
      return fallthrough;
    }

    case "BsAssign": {
      const [lhs, rhs] = node.contents;
      const varName = lhs.segments[0]?.name;
      if (varName && rhs.tag !== "ExRaw") {
        const pc = b.emit({ kind: "assign", var: varName, rhs, next: fallthrough }, line);
        return pc;
      }
      return fallthrough;
    }

    case "BsCall": {
      const expr = node.contents;
      const classification = classifyCall(expr);
      if (classification === "suspend") {
        const name = calleeName(expr);
        const effectName = name.endsWith(".retrieve") ? "executeSql" : name.toLowerCase();
        const args = expr.tag === "ExCall" ? expr.args.flat() : [];
        const suspendExprs = parseSuspendArgs(args);
        const pc = b.emit({
          kind: "suspend",
          effect: effectName,
          args: suspendExprs,
          continuation: fallthrough,
        }, line);
        return pc;
      }
      // Pure call
      const callee = calleeName(expr);
      const rawArgs = expr.tag === "ExCall" ? expr.args.flat() : [];
      const callExprs = parseSuspendArgs(rawArgs);
      const pc = b.emit({
        kind: "call",
        callee,
        args: callExprs,
        next: fallthrough,
      }, line);
      return pc;
    }

    case "BsReturn": {
      const pc = b.emit({ kind: "return", value: node.contents ?? undefined }, line);
      return pc;
    }

    case "BsIf": {
      const mergePc = fallthrough;
      const { cond, then: thenBody, elseIfs, else: elseBody } = node.contents;

      // Compile else branch (falls through to merge)
      let elseEntry = mergePc;
      if (elseBody && elseBody.length > 0) {
        elseEntry = compileStmts(elseBody, mergePc, b);
      }

      // Compile else-if branches (each falls through to merge)
      let currentFalse = elseEntry;
      for (let i = elseIfs.length - 1; i >= 0; i--) {
        const ei = elseIfs[i]!;
        const eiBody = compileStmts(ei.body, mergePc, b);
        currentFalse = b.emit({ kind: "branch", cond: ei.cond, then_: eiBody, else_: currentFalse }, line);
      }

      // Compile then branch (falls through to merge)
      const thenEntry = compileStmts(thenBody, mergePc, b);

      // Branch on condition
      const pc = b.emit({ kind: "branch", cond, then_: thenEntry, else_: currentFalse }, line);
      return pc;
    }

    case "BsFor": {
      const fv = node.contents;
      const varName = fv.var?.segments[0]?.name;
      if (!varName) return fallthrough;

      const condPc = b.nodes.length;    // will be patched

      // Compile body (loops back to cond)
      compileStmts(fv.body, condPc, b);

      // Increment: i = i + step
      const stepExpr: Expr = fv.step ?? { tag: "ExInt", contents: "1" };
      const incrPc = b.emit({
        kind: "assign",
        var: varName,
        rhs: {
          tag: "ExBinOp",
          lhs: { tag: "ExLvalue", contents: { segments: [{ name: varName, subscript: null }] } },
          op: "BopAdd",
          rhs: stepExpr,
        } as Expr,
        next: condPc,
      });

      // Condition: i <= to
      const branchPc = b.emit({
        kind: "branch",
        cond: {
          tag: "ExBinOp",
          lhs: { tag: "ExLvalue", contents: { segments: [{ name: varName, subscript: null }] } },
          op: "BopLe",
          rhs: fv.to,
        } as Expr,
        then_: incrPc,
        else_: fallthrough,
      });

      // Initialize: i = from
      const initPc = b.emit({
        kind: "assign",
        var: varName,
        rhs: fv.from,
        next: branchPc,
      }, line);

      return initPc;
    }

    case "BsDo": {
      const dv = node.contents;
      const bodyEntry = b.nodes.length;

      // Compile body
      const bodyExit = compileStmts(dv.body, bodyEntry, b);

      if (dv.cond) {
        // DO WHILE condition: check at top
        const condPc = b.emit({
          kind: "branch",
          cond: dv.cond.contents,
          then_: bodyExit,
          else_: fallthrough,
        });
        return condPc;
      }

      if (dv.loop) {
        // DO ... LOOP WHILE/UNTIL: check at bottom
        b.emit({
          kind: "branch",
          cond: dv.loop.contents,
          then_: bodyEntry,
          else_: fallthrough,
        });
        return bodyEntry;
      }

      // DO ... LOOP (infinite)
      return bodyEntry;
    }

    case "BsChoose": {
      const cv = node.contents;
      // For now, treat as a chain of branches
      // Each clause: branch on value == clause, then execute body
      let nextPc = fallthrough;
      for (let i = cv.clauses.length - 1; i >= 0; i--) {
        const clause = cv.clauses[i]!;
        if (clause.expr === null) {
          // case else — unconditional
          nextPc = compileStmts(clause.body, fallthrough, b);
        } else {
          const bodyPc = compileStmts(clause.body, fallthrough, b);
          const clauseExprs = clause.expr as unknown as Expr[];
          const clauseExpr = clauseExprs[0] ?? { tag: "ExNull" };
          nextPc = b.emit({
            kind: "branch",
            cond: {
              tag: "ExBinOp",
              lhs: cv.expr,
              op: "BopEq",
              rhs: clauseExpr,
            } as Expr,
            then_: bodyPc,
            else_: nextPc,
          }, line);
        }
      }
      return nextPc;
    }

    case "BsExit":
    case "BsContinue":
      // Treated as no-ops for now (loop control handled at a higher level)
      return fallthrough;

    case "BsRaw":
      // Skip raw statements (call super::open, etc.)
      return fallthrough;

    default:
      return fallthrough;
  }
}

function parseSuspendArgs(tokens: string[]): Expr[] {
  // Tokens are raw strings; convert to simple expressions
  return tokens.map((t) => {
    const raw = t.trim();
    if (raw.startsWith('"') && raw.endsWith('"')) {
      return { tag: "ExStr", contents: raw.slice(1, -1) } as Expr;
    }
    if (/^[a-zA-Z_]/.test(raw)) {
      return {
        tag: "ExLvalue",
        contents: { segments: [{ name: raw, subscript: null }] },
      } as Expr;
    }
    return { tag: "ExStr", contents: raw } as Expr;
  });
}
