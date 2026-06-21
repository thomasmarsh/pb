// features/runtime/reducer.ts — CPS-encoded PB interpreter as a TCA reducer.
//
// Each retrieve() call is a labeled suspension point: the reducer returns an
// Effect and resumes when sql-result arrives. Pure statements (assign, if, for,
// etc.) execute synchronously without leaving the reducer.

import { Effect } from "../../core/effect.js";
import type { Reducer } from "../../core/reducer.js";
import type { AstData, DWRow } from "../../core/interpreter.js";
import type { BodyStmt, Expr, Located } from "../../types/ast.generated.js";
import { DW_QUERIES, type SQLResult } from "../../core/dw-queries.js";
import { PB_BUILTINS } from "../../core/runtime.js";

// ── Global variables ──────────────────────────────────────────────────────────

// Pre-populated before each run-event; seeded only if not already set.
export const PB_GLOBALS: Record<string, unknown> = {
  gs_kodxrisi: "0001",
  gs_app_name: "OpenPay",
  gs_username: "admin",
};

// ── Env ───────────────────────────────────────────────────────────────────────

export interface RuntimeEnv {
  executeSql(sql: string, params: unknown[]): Effect<SQLResult>;
}

// ── State ─────────────────────────────────────────────────────────────────────

export interface RuntimeState {
  ast: AstData | null;
  variables: Record<string, unknown>;
  controlValues: Record<string, DWRow[]>;
  // Remaining top-level statements after a sql suspension point.
  continuation: Located<BodyStmt>[] | null;
  status: "idle" | "running" | "awaiting-sql" | "done" | "error";
  error: string | null;
}

export const initialRuntimeState: RuntimeState = {
  ast: null,
  variables: {},
  controlValues: {},
  continuation: null,
  status: "idle",
  error: null,
};

// ── Actions ───────────────────────────────────────────────────────────────────

export type RuntimeAction =
  | { tag: "set-ast"; ast: AstData }
  | { tag: "run-event"; owner: string; event: string }
  | { tag: "control-click"; controlName: string }
  | { tag: "sql-result"; dwName: string; rows: DWRow[] }
  | { tag: "error"; message: string };

// ── Sync expression evaluator ─────────────────────────────────────────────────

function evalTokenArg(vars: Record<string, unknown>, tokens: string[]): unknown {
  if (tokens.length === 0) return undefined;
  const raw = tokens.join("").trim();
  if (raw === "null") return null;
  if (raw === "true") return true;
  if (raw === "false") return false;
  if (raw.startsWith('"') && raw.endsWith('"')) return raw.slice(1, -1);
  if (/^-?\d+$/.test(raw)) return parseInt(raw, 10);
  if (/^-?\d+\.\d+$/.test(raw)) return parseFloat(raw);
  if (/^[a-zA-Z_]/.test(raw)) {
    const dotIdx = raw.indexOf(".");
    const base = dotIdx >= 0 ? raw.slice(0, dotIdx) : raw;
    return vars[base];
  }
  return raw;
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

function evalExpr(vars: Record<string, unknown>, expr: Expr): unknown {
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
      return name ? vars[name] : undefined;
    }
    case "ExCall": {
      const callee = expr.callee.segments.map((s) => s.name).join(".");
      const args = expr.args.map((a) => evalTokenArg(vars, a));
      const fn = PB_BUILTINS[callee];
      return fn ? fn(...args) : undefined;
    }
    case "ExBinOp":
      return evalBinOp(evalExpr(vars, expr.lhs), expr.op, evalExpr(vars, expr.rhs));
    case "ExNot":    return !evalExpr(vars, expr.contents);
    case "ExNeg":    return -(evalExpr(vars, expr.contents) as number);
    // ExMethodCall retrieve() is intercepted above in checkRetrieve before evalExpr is called.
    // Other method calls and unrecognized expressions are no-ops.
    default:         return undefined;
  }
}

// ── Retrieve suspension detection ─────────────────────────────────────────────

interface SuspendRetrieve {
  dwName: string;
  sql: string;
  params: unknown[];
}

// Scan typeBlocks for a control's dataobject value (e.g. "dw" → "dw_misth_zpkrat_list").
function findDwDataobject(ast: AstData | null, controlName: string): string | null {
  if (!ast) return null;
  for (const tb of ast.typeBlocks) {
    if (tb.decl.within !== null && tb.decl.name === controlName) {
      for (const s of tb.body) {
        if (
          s.node.tag === "BsLocalVar" &&
          s.node.name === "dataobject" &&
          s.node.init?.tag === "ExStr"
        ) {
          return (s.node.init as { tag: "ExStr"; contents: string }).contents;
        }
      }
    }
  }
  return null;
}

function checkRetrieve(
  vars: Record<string, unknown>,
  expr: Expr,
  ast?: AstData | null,
): SuspendRetrieve | null {
  // Corpus pattern: ExCall with 2-segment callee [dw_name, retrieve]
  // PB parser emits this for `dw_foo.retrieve(args)` at statement level.
  if (expr.tag === "ExCall") {
    const segs = expr.callee.segments;
    // Pattern 1: dw_foo.retrieve(args) — explicit DW control name
    if (
      segs.length === 2 &&
      segs[0]!.name.startsWith("dw_") &&
      segs[1]!.name.toLowerCase() === "retrieve"
    ) {
      const dwName = segs[0]!.name;
      const sql = DW_QUERIES[dwName];
      if (sql) {
        const params = expr.args.map((a) => evalTokenArg(vars, a));
        return { dwName, sql, params };
      }
      return null;
    }
    // Pattern 2: fn_retrievechild(adw, "col", arg) — global helper from afxlib.pbl.
    // The function body calls ldwch.retrieve(arg) on a child DW for the named column.
    // Since fn_retrievechild is cross-library and absent from window ASTs, we intercept
    // it at the call site and map the column name to a known DW_QUERIES entry.
    if (
      segs.length === 1 &&
      segs[0]!.name === "fn_retrievechild" &&
      expr.args.length === 3
    ) {
      const colRaw = (expr.args[1] ?? []).join("").trim().replace(/^"|"$/g, "");
      const dwName = `child_${colRaw}`;
      const sql = DW_QUERIES[dwName];
      if (sql) {
        const param = evalTokenArg(vars, expr.args[2] ?? []);
        return { dwName, sql, params: [param] };
      }
      return null;
    }
    // Pattern 3: dw.retrieve() — control named "dw" (from ancestor subroutines like of_retrieve).
    // Look up the dataobject from typeBlocks; pass gs_kodxrisi if the query is parameterised.
    if (
      segs.length === 2 &&
      segs[0]!.name === "dw" &&
      segs[1]!.name.toLowerCase() === "retrieve"
    ) {
      const dataobj = findDwDataobject(ast ?? null, "dw");
      if (dataobj) {
        const sql = DW_QUERIES[dataobj];
        if (sql) {
          const params = sql.includes("?") ? [vars["gs_kodxrisi"]] : [];
          // Store under the control name "dw", not the dataobject name, so
          // RuntimeView can look it up as controlValues[ctrl.name].
          return { dwName: "dw", sql, params };
        }
      }
      return null;
    }
    return null;
  }
  // ExMethodCall pattern: complex receiver expression (e.g. chained call).retrieve(args)
  if (expr.tag === "ExMethodCall") {
    if (expr.receiver.tag !== "ExLvalue") return null;
    const dwName = expr.receiver.contents.segments[0]?.name ?? "";
    if (!dwName.startsWith("dw_")) return null;
    if (expr.method.toLowerCase() !== "retrieve") return null;
    const sql = DW_QUERIES[dwName];
    if (!sql) return null;
    const params = expr.args.map((a) => evalTokenArg(vars, a));
    return { dwName, sql, params };
  }
  return null;
}

// ── Synchronous body executor (for control-flow bodies that lack retrieve()) ──
// retrieve() inside BsIf/BsFor/BsDo bodies is out of scope for 101c (BACKLOG).

function execBodySync(vars: Record<string, unknown>, stmts: Located<BodyStmt>[], ast?: AstData | null): void {
  for (const s of stmts) {
    execStmtSync(vars, s.node, ast);
  }
}

function execStmtSync(vars: Record<string, unknown>, node: BodyStmt, ast?: AstData | null): void {
  switch (node.tag) {
    case "BsAssign": {
      const [lhs, rhs] = node.contents;
      if (checkRetrieve(vars, rhs, ast)) return; // skip — retrieve() in control flow is BACKLOG
      const name = lhs.segments[0]?.name;
      if (name) vars[name] = evalExpr(vars, rhs);
      return;
    }
    case "BsCall":
      // retrieve() inside control flow is a no-op for 101c
      if (!checkRetrieve(vars, node.contents, ast)) evalExpr(vars, node.contents);
      return;
    case "BsLocalVar":
      if (node.init && !checkRetrieve(vars, node.init, ast)) {
        vars[node.name] = evalExpr(vars, node.init);
      }
      return;
    case "BsReturn":
      return;
    case "BsIf": {
      const { cond, then, elseIfs, else: elseBody } = node.contents;
      if (evalExpr(vars, cond)) {
        execBodySync(vars, then, ast);
      } else {
        let taken = false;
        for (const ei of elseIfs) {
          if (evalExpr(vars, ei.cond)) { execBodySync(vars, ei.body, ast); taken = true; break; }
        }
        if (!taken && elseBody) execBodySync(vars, elseBody, ast);
      }
      return;
    }
    case "BsFor": {
      const fv = node.contents;
      const varName = fv.var?.segments[0]?.name;
      if (!varName) return;
      const from = Number(evalExpr(vars, fv.from));
      const to   = Number(evalExpr(vars, fv.to));
      const step = fv.step ? Number(evalExpr(vars, fv.step)) : 1;
      if (step === 0) return;
      for (let i = from; step > 0 ? i <= to : i >= to; i += step) {
        vars[varName] = i;
        execBodySync(vars, fv.body, ast);
      }
      return;
    }
    case "BsDo": {
      const dv = node.contents;
      if (!dv.cond && !dv.loop) { execBodySync(vars, dv.body, ast); return; }
      const cond = dv.cond ?? dv.loop!;
      const isWhile = cond.tag === "DoWhile";
      const condExpr = cond.contents;
      // Guard against infinite loops in sync executor
      let guard = 10000;
      do {
        execBodySync(vars, dv.body, ast);
      } while (guard-- > 0 && (isWhile ? evalExpr(vars, condExpr) : !evalExpr(vars, condExpr)));
      return;
    }
    case "BsChoose": {
      const cv = node.contents;
      const value = evalExpr(vars, cv.expr);
      for (const clause of cv.clauses) {
        if (clause.expr === null) { execBodySync(vars, clause.body, ast); return; }
        const cv2 = evalTokenArg(vars, clause.expr);
        if (value === cv2 || String(value) === String(cv2)) { execBodySync(vars, clause.body, ast); return; }
      }
      return;
    }
    default:
      return;
  }
}

// ── Top-level statement executor (can suspend on retrieve()) ──────────────────

function execStmt(
  draft: RuntimeState,
  node: BodyStmt,
): SuspendRetrieve | null {
  switch (node.tag) {
    case "BsCall": {
      const suspend = checkRetrieve(draft.variables, node.contents, draft.ast);
      if (suspend) return suspend;
      evalExpr(draft.variables, node.contents);
      return null;
    }
    case "BsAssign": {
      const [lhs, rhs] = node.contents;
      const suspend = checkRetrieve(draft.variables, rhs, draft.ast);
      if (suspend) return suspend;
      const name = lhs.segments[0]?.name;
      if (name) draft.variables[name] = evalExpr(draft.variables, rhs);
      return null;
    }
    case "BsLocalVar":
      if (node.init) {
        const suspend = checkRetrieve(draft.variables, node.init, draft.ast);
        if (suspend) return suspend;
        draft.variables[node.name] = evalExpr(draft.variables, node.init);
      }
      return null;
    case "BsReturn":
      return null;
    // Control flow runs synchronously; retrieve() inside them is BACKLOG.
    case "BsIf":
    case "BsFor":
    case "BsDo":
    case "BsChoose":
      execStmtSync(draft.variables, node, draft.ast);
      return null;
    default:
      return null;
  }
}

// ── Trampoline driver ─────────────────────────────────────────────────────────

function driveStmts(
  draft: RuntimeState,
  stmts: Located<BodyStmt>[],
  env: RuntimeEnv,
  superDispatched = false,
): Effect<RuntimeAction> | null {
  for (let i = 0; i < stmts.length; i++) {
    const node = stmts[i]!.node;

    // BsRaw containing "call super::open" — inline-expand the ancestor's open event body.
    // Only follow once (superDispatched guard) to avoid infinite recursion when the ancestor
    // body itself also contains "call super::open" (calling window::open).
    if (
      !superDispatched &&
      node.tag === "BsRaw" &&
      typeof node.contents === "string" &&
      node.contents.includes("call super::open") &&
      draft.ast
    ) {
      const ancestorOpen = draft.ast.ancestorEvents?.find(
        e => e.name.toLowerCase() === "open"
      );
      if (ancestorOpen) {
        return driveStmts(draft, [...ancestorOpen.body, ...stmts.slice(i + 1)], env, true);
      }
    }

    // TriggerEvent("eventName") / this.TriggerEvent("eventName") — inline-expand the named event.
    if (node.tag === "BsCall" && node.contents.tag === "ExCall" && draft.ast) {
      const segs = node.contents.callee.segments;
      const lastName = segs[segs.length - 1]?.name.toLowerCase();
      const isTrigger =
        (segs.length === 1 || (segs.length === 2 && segs[0]!.name.toLowerCase() === "this")) &&
        lastName === "triggerevent";
      if (isTrigger && node.contents.args.length > 0) {
        const eventName = (node.contents.args[0] ?? [])
          .join("")
          .trim()
          .replace(/^"|"$/g, "");
        const eventBody = findEventByName(draft.ast, eventName);
        if (eventBody) {
          return driveStmts(draft, [...eventBody, ...stmts.slice(i + 1)], env, superDispatched);
        }
      }
    }

    // User-defined function dispatch: if the statement is a single-segment ExCall
    // whose name matches a function/subroutine, inline-expand its body in place.
    // Note: fn_retrievechild is caught by checkRetrieve before reaching here.
    // Functions that depend on external resources unavailable in the runtime
    // (INI files, system calls) are skipped — they fall through to the no-op
    // ExCall path in execStmt rather than being inline-expanded.
    const SKIP_EXPAND = new Set(["if_readini", "if_readinistr", "if_setwhere"]);
    if (node.tag === "BsCall" && node.contents.tag === "ExCall" && draft.ast) {
      const segs = node.contents.callee.segments;
      if (segs.length === 1 && !SKIP_EXPAND.has(segs[0]!.name.toLowerCase())) {
        const fnBody = findBodyByName(draft.ast, segs[0]!.name);
        if (fnBody) {
          return driveStmts(draft, [...fnBody, ...stmts.slice(i + 1)], env, superDispatched);
        }
      }
    }
    // Inline-expand BsIf branches so that TriggerEvent and retrieve() inside
    // conditions flow through the trampoline rather than the sync executor.
    if (node.tag === "BsIf") {
      const { cond, then: thenBody, elseIfs, else: elseBody } = node.contents;
      let branchBody: Located<BodyStmt>[] = [];
      if (evalExpr(draft.variables, cond)) {
        branchBody = thenBody;
      } else {
        let taken = false;
        for (const ei of elseIfs) {
          if (evalExpr(draft.variables, ei.cond)) { branchBody = ei.body; taken = true; break; }
        }
        if (!taken && elseBody) branchBody = elseBody;
      }
      return driveStmts(draft, [...branchBody, ...stmts.slice(i + 1)], env, superDispatched);
    }

    const suspend = execStmt(draft, node);
    if (suspend !== null) {
      draft.continuation = stmts.slice(i + 1);
      draft.status = "awaiting-sql";
      return env.executeSql(suspend.sql, suspend.params)
        .map((r): RuntimeAction => ({ tag: "sql-result", dwName: suspend.dwName, rows: r.rows }))
        .catch((e): RuntimeAction => ({ tag: "error", message: String(e) }));
    }
  }
  draft.continuation = null;
  draft.status = "done";
  return null;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function findBody(
  ast: AstData,
  owner: string,
  event: string,
): Located<BodyStmt>[] | null {
  const key = `${owner}::${event}`.toLowerCase();
  for (const e of ast.events) {
    if (`${e.owner}::${e.name}`.toLowerCase() === key) return e.body;
  }
  for (const f of ast.functions ?? []) {
    if (`${f.owner}::${f.name}`.toLowerCase() === key) return f.body;
  }
  return null;
}

// Find an event by name: current window first, then ancestor events.
function findEventByName(ast: AstData, eventName: string): Located<BodyStmt>[] | null {
  const name = eventName.toLowerCase();
  for (const e of ast.events) {
    if (e.name.toLowerCase() === name) return e.body;
  }
  for (const e of ast.ancestorEvents ?? []) {
    if (e.name.toLowerCase() === name) return e.body;
  }
  return null;
}

// Scan functions by name only (ignoring owner) for user-defined function dispatch.
// Searches window functions first, then ancestor subroutines/functions.
function findBodyByName(
  ast: AstData,
  fnName: string,
): Located<BodyStmt>[] | null {
  const name = fnName.toLowerCase();
  for (const f of ast.functions ?? []) {
    if (f.name.toLowerCase() === name) return f.body;
  }
  for (const f of ast.ancestorFunctions ?? []) {
    if (f.name.toLowerCase() === name) return f.body;
  }
  return null;
}

// ── Reducer ───────────────────────────────────────────────────────────────────

function reduce(
  draft: RuntimeState,
  action: RuntimeAction,
  env: RuntimeEnv,
): Effect<RuntimeAction> | null {
  switch (action.tag) {
    case "set-ast":
      draft.ast = action.ast;
      draft.variables = {};
      draft.controlValues = {};
      draft.continuation = null;
      draft.status = "idle";
      draft.error = null;
      return null;

    case "run-event": {
      if (!draft.ast) return null;
      for (const [k, v] of Object.entries(PB_GLOBALS)) {
        if (!(k in draft.variables)) draft.variables[k] = v;
      }
      // Seed window instance variable declarations (e.g. ib_retrieve = true)
      // from the window typeBlock body so BsIf conditions evaluate correctly.
      const windowTb = draft.ast.typeBlocks.find(tb => tb.decl.within == null);
      if (windowTb) {
        for (const s of windowTb.body) {
          const n = s.node;
          if (n.tag === "BsLocalVar" && n.init && !(n.name in draft.variables)) {
            draft.variables[n.name] = evalExpr(draft.variables, n.init);
          }
        }
      }
      draft.status = "running";
      const body = findBody(draft.ast, action.owner, action.event);
      if (!body) { draft.status = "done"; return null; }
      return driveStmts(draft, body, env);
    }

    case "control-click": {
      if (!draft.ast) return null;
      draft.status = "running";
      const body = findBody(draft.ast, action.controlName, "clicked");
      if (!body) { draft.status = "done"; return null; }
      return driveStmts(draft, body, env);
    }

    case "sql-result":
      draft.controlValues[action.dwName] = action.rows;
      if (draft.continuation && draft.continuation.length > 0) {
        const cont = draft.continuation;
        draft.continuation = null;
        return driveStmts(draft, cont, env);
      }
      draft.continuation = null;
      draft.status = "done";
      return null;

    case "error":
      draft.status = "error";
      draft.error = action.message;
      return null;
  }
}

export const runtimeReducer: Reducer<RuntimeState, RuntimeAction, RuntimeEnv> = reduce;
