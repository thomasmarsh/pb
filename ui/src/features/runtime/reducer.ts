// features/runtime/reducer.ts — CPS-encoded PB interpreter as a TCA reducer.
//
// Each retrieve() call is a labeled suspension point: the reducer returns an
// Effect and resumes when sql-result (tree-walk) or cps-resume (CPS) arrives.
// Pure statements execute synchronously without leaving the reducer.

import { Effect } from "../../core/effect.js";
import type { Reducer } from "../../core/reducer.js";
import type { AstData, DWRow, ProcEntry } from "../../core/interpreter.js";
import type { BodyStmt, Expr, Located } from "../../types/ast.generated.js";
import { DW_QUERIES, type SQLResult } from "../../core/dw-queries.js";
import { loadCpsGraph } from "../../core/cps/load.js";
import { step, type CpsResumeAction } from "../../core/cps/runner.js";
import type { CpsGraph } from "../../core/cps/types.js";
// evalExpr is the single evaluator — shared between CPS and tree-walk paths.
import { evalExpr, evalTokenArg } from "../../core/cps/expr.js";
import { type VarEnv, makeVarEnv, readVar, writeVar, declareLocal, pushFrame, popFrame } from "../../core/cps/var-env.js";

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
  varEnv: VarEnv;
  controlValues: Record<string, DWRow[]>;
  // Tree-walk continuation (remaining statements after a SQL suspension).
  continuation: Located<BodyStmt>[] | null;
  // Saved caller continuations for tree-walk procedure calls.
  treeWalkStack: Located<BodyStmt>[][];
  // CPS-mode graph held for cps-resume; null when using tree-walk path.
  cpsGraph: CpsGraph | null;
  // Plan 115 item 2: CPS call stack for CpsCallProc dispatch. Each frame holds
  // the suspended graph and the PC to resume at once the callee body finishes.
  callStack: { graph: CpsGraph; resumePc: number }[];
  status: "idle" | "running" | "awaiting-sql" | "done" | "error";
  error: string | null;
}

export const initialRuntimeState: RuntimeState = {
  ast: null,
  varEnv: makeVarEnv(),
  controlValues: {},
  continuation: null,
  treeWalkStack: [],
  cpsGraph: null,
  callStack: [],
  status: "idle",
  error: null,
};

// ── Actions ───────────────────────────────────────────────────────────────────

export type RuntimeAction =
  | { tag: "set-ast"; ast: AstData }
  | { tag: "run-event"; owner: string; event: string }
  | { tag: "control-click"; controlName: string }
  | { tag: "sql-result"; dwName: string; rows: DWRow[] }
  | { tag: "cps-resume"; dwName: string; rows: DWRow[]; pc: number; varName: string | null }
  // Plan 115 item 2: dispatch a CALL ancestor::event / TriggerEvent to a body
  // found via the AST. Pushes the current graph and resumes at resumePc.
  | { tag: "cps-dispatch"; callee: string; args: unknown[]; resumePc: number }
  | { tag: "error"; message: string };

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

// Extract the DW target name and evaluated params from a retrieve-pattern expression.
// Returns null if the expression is not a retrieve call.
interface RetrieveTarget { dwName: string; params: unknown[]; sqlLookup?: string }

function extractRetrieveTarget(
  varEnv: VarEnv,
  expr: Expr,
  ast?: AstData | null,
): RetrieveTarget | null {
  if (expr.tag === "ExCall") {
    const segs = expr.callee.segments;
    // Pattern 1: dw_foo.retrieve(args)
    if (segs.length === 2 && segs[0]!.name.startsWith("dw_") && segs[1]!.name.toLowerCase() === "retrieve") {
      return { dwName: segs[0]!.name, params: expr.args.map((a) => evalTokenArg(varEnv, a)) };
    }
    // Pattern 2: fn_retrievechild(adw, "col", arg)
    if (segs.length === 1 && segs[0]!.name === "fn_retrievechild" && expr.args.length === 3) {
      const colRaw = (expr.args[1] ?? []).join("").trim().replace(/^"|"$/g, "");
      return { dwName: `child_${colRaw}`, params: [evalTokenArg(varEnv, expr.args[2] ?? [])] };
    }
    // Pattern 3: dw.retrieve() — resolve via dataobject from typeBlocks
    if (segs.length === 2 && segs[0]!.name === "dw" && segs[1]!.name.toLowerCase() === "retrieve") {
      const dataobj = findDwDataobject(ast ?? null, "dw");
      if (!dataobj) return null;
      // Control name is "dw" but SQL lookup uses the dataobject name.
      return { dwName: "dw", params: [], sqlLookup: dataobj };
    }
    return null;
  }
  // Pattern 4: ExMethodCall — dw_foo.retrieve(args)
  if (expr.tag === "ExMethodCall" && expr.receiver.tag === "ExLvalue") {
    const dwName = expr.receiver.contents.segments[0]?.name ?? "";
    if (dwName.startsWith("dw_") && expr.method.toLowerCase() === "retrieve") {
      return { dwName, params: expr.args.map((a) => evalTokenArg(varEnv, a)) };
    }
  }
  return null;
}

function checkRetrieve(
  varEnv: VarEnv,
  expr: Expr,
  ast?: AstData | null,
): SuspendRetrieve | null {
  const target = extractRetrieveTarget(varEnv, expr, ast);
  if (!target) return null;
  const sqlKey = target.sqlLookup ?? target.dwName;
  const sql = DW_QUERIES[sqlKey];
  if (!sql) return null;
  const params = sql.includes("?") && target.params.length === 0
    ? [readVar(varEnv, "gs_kodxrisi")]
    : target.params;
  return { dwName: target.dwName, sql, params };
}

// ── Synchronous loop/choose executor (control-flow that cannot suspend) ─────

function runBodySync(varEnv: VarEnv, stmts: Located<BodyStmt>[], ast?: AstData | null): void {
  for (const s of stmts) {
    const node = s.node;
    if (node.tag === "BsFor") {
      const fv = node.contents;
      const varName = fv.var?.segments[0]?.name;
      if (!varName) continue;
      const from = Number(evalExpr(varEnv, fv.from));
      const to = Number(evalExpr(varEnv, fv.to));
      const step_ = fv.step ? Number(evalExpr(varEnv, fv.step)) : 1;
      if (step_ === 0) continue;
      for (let i = from; step_ > 0 ? i <= to : i >= to; i += step_) {
        writeVar(varEnv, varName, i);
        runBodySync(varEnv, fv.body, ast);
      }
    } else if (node.tag === "BsDo") {
      const dv = node.contents;
      if (!dv.cond && !dv.loop) { runBodySync(varEnv, dv.body, ast); continue; }
      const cond = dv.cond ?? dv.loop!;
      const isWhile = cond.tag === "DoWhile";
      const condExpr = cond.contents;
      let guard = 10000;
      do { runBodySync(varEnv, dv.body, ast); }
      while (guard-- > 0 && (isWhile ? evalExpr(varEnv, condExpr) : !evalExpr(varEnv, condExpr)));
    } else if (node.tag === "BsChoose") {
      const cv = node.contents;
      const value = evalExpr(varEnv, cv.expr);
      for (const clause of cv.clauses) {
        if (clause.expr === null) { runBodySync(varEnv, clause.body, ast); break; }
        const cv2 = evalTokenArg(varEnv, clause.expr);
        if (value === cv2 || String(value) === String(cv2)) { runBodySync(varEnv, clause.body, ast); break; }
      }
    } else if (node.tag === "BsAssign") {
      const [lhs, rhs] = node.contents;
      const name = lhs.segments[0]?.name;
      if (name) writeVar(varEnv, name, evalExpr(varEnv, rhs));
    } else if (node.tag === "BsLocalVar" && node.init) {
      declareLocal(varEnv, node.name, evalExpr(varEnv, node.init));
    } else if (node.tag === "BsIf") {
      const { cond, then: thenBody, elseIfs, else: elseBody } = node.contents;
      if (evalExpr(varEnv, cond)) {
        runBodySync(varEnv, thenBody, ast);
      } else {
        const matched = elseIfs.find(ei => evalExpr(varEnv, ei.cond));
        if (matched) runBodySync(varEnv, matched.body, ast);
        else if (elseBody) runBodySync(varEnv, elseBody, ast);
      }
    } else if (node.tag === "BsCall") {
      evalExpr(varEnv, node.contents);
    }
    // BsReturn, BsPbCall, BsExit, BsContinue, BsAugAssign etc. are treated as no-ops inside loops.
    // Retrieve() inside loop bodies is BACKLOG.
  }
}

// ── Call-stack unwind (tree-walk path) ────────────────────────────────────────

// Called at the end of every driveStmts invocation (normal completion or BsReturn).
// Pops the caller's continuation off treeWalkStack and resumes it with popFrame;
// if the stack is empty, checks the CPS callStack or marks the run as done.
function unwindCallStack(
  draft: RuntimeState,
  env: RuntimeEnv,
): Effect<RuntimeAction> | null {
  const callerCont = draft.treeWalkStack.pop();
  if (!callerCont) {
    if (draft.callStack.length > 0) return popCallStack(draft, env);
    draft.continuation = null;
    draft.status = "done";
    return null;
  }
  popFrame(draft.varEnv);
  return driveStmts(draft, callerCont, env);
}

// ── Trampoline driver (tree-walk path) ────────────────────────────────────────

function driveStmts(
  draft: RuntimeState,
  stmts: Located<BodyStmt>[],
  env: RuntimeEnv,
  superDispatched = false,
): Effect<RuntimeAction> | null {
  for (let i = 0; i < stmts.length; i++) {
    const node = stmts[i]!.node;

    // BsRaw containing "call super::open" — push a frame, save caller continuation,
    // then run the ancestor open body. Only follow once (superDispatched guard).
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
        pushFrame(draft.varEnv);
        draft.treeWalkStack.push(stmts.slice(i + 1));
        return driveStmts(draft, ancestorOpen.body, env, true);
      }
    }

    // TriggerEvent("eventName") / this.TriggerEvent("eventName") — push a frame,
    // save caller continuation, then run the named event body.
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
          pushFrame(draft.varEnv);
          draft.treeWalkStack.push(stmts.slice(i + 1));
          return driveStmts(draft, eventBody, env, superDispatched);
        }
      }
    }

    // User-defined function dispatch: push a frame, save caller continuation,
    // then run the callee body. fn_retrievechild is caught by checkRetrieve before
    // reaching here. Functions depending on external resources are skipped.
    const SKIP_EXPAND = new Set(["if_readini", "if_readinistr", "if_setwhere"]);
    if (node.tag === "BsCall" && node.contents.tag === "ExCall" && draft.ast) {
      const segs = node.contents.callee.segments;
      if (segs.length === 1 && !SKIP_EXPAND.has(segs[0]!.name.toLowerCase())) {
        const fnBody = findBodyByName(draft.ast, segs[0]!.name);
        if (fnBody) {
          pushFrame(draft.varEnv);
          draft.treeWalkStack.push(stmts.slice(i + 1));
          return driveStmts(draft, fnBody, env, false);
        }
      }
    }

    // Inline-expand BsIf branches (no frame boundary — same procedure scope).
    if (node.tag === "BsIf") {
      const { cond, then: thenBody, elseIfs, else: elseBody } = node.contents;
      let branchBody: Located<BodyStmt>[] = [];
      if (evalExpr(draft.varEnv, cond)) {
        branchBody = thenBody;
      } else {
        let taken = false;
        for (const ei of elseIfs) {
          if (evalExpr(draft.varEnv, ei.cond)) { branchBody = ei.body; taken = true; break; }
        }
        if (!taken && elseBody) branchBody = elseBody;
      }
      return driveStmts(draft, [...branchBody, ...stmts.slice(i + 1)], env, superDispatched);
    }

    // BsReturn — stop this body and let unwindCallStack resume the caller.
    if (node.tag === "BsReturn") break;

    // ── Inline statement execution ────────────────────────────────────────────

    let suspend: SuspendRetrieve | null = null;

    if (node.tag === "BsCall") {
      suspend = checkRetrieve(draft.varEnv, node.contents, draft.ast);
      if (!suspend) evalExpr(draft.varEnv, node.contents);
    } else if (node.tag === "BsAssign") {
      const [lhs, rhs] = node.contents;
      suspend = checkRetrieve(draft.varEnv, rhs, draft.ast);
      if (!suspend) {
        const name = lhs.segments[0]?.name;
        if (name) writeVar(draft.varEnv, name, evalExpr(draft.varEnv, rhs));
      }
    } else if (node.tag === "BsLocalVar" && node.init) {
      suspend = checkRetrieve(draft.varEnv, node.init, draft.ast);
      if (!suspend) declareLocal(draft.varEnv, node.name, evalExpr(draft.varEnv, node.init));
    } else if (node.tag === "BsFor" || node.tag === "BsDo" || node.tag === "BsChoose") {
      // Loops run synchronously; retrieve() inside them is BACKLOG.
      runBodySync(draft.varEnv, [stmts[i]!], draft.ast);
    }
    // All other tags (BsExit, BsContinue, etc.) → fall through, no suspend.

    if (suspend !== null) {
      draft.continuation = stmts.slice(i + 1);
      draft.status = "awaiting-sql";
      return env.executeSql(suspend.sql, suspend.params)
        .map((r): RuntimeAction => ({ tag: "sql-result", dwName: suspend.dwName, rows: r.rows }))
        .catch((e): RuntimeAction => ({ tag: "error", message: String(e) }));
    }
  }
  return unwindCallStack(draft, env);
}

// ── CPS execution path ────────────────────────────────────────────────────────

// Returns true if any suspend node uses the raw "executeSql" effect, which
// means the graph contains fn_retrievechild or other patterns that require
// the tree-walk's checkRetrieve logic.
function graphNeedsTreeWalk(graph: CpsGraph): boolean {
  return graph.nodes.some(n => n.kind === "suspend" && n.effect === "executeSql");
}

// Drive a loaded CPS graph from pc, producing a RuntimeAction Effect on suspend.
function stepWithDraft(
  graph: CpsGraph,
  pc: number,
  draft: RuntimeState,
  env: RuntimeEnv,
): Effect<RuntimeAction> | null {
  const cpsEnv = {
    executeSql: env.executeSql,
    open: (): Effect<unknown> => Effect.none(),
    dwNameToSql: (dwName: string): string | null => DW_QUERIES[dwName] ?? null,
  };
  const effect = step(graph, pc, draft.varEnv, cpsEnv);
  if (!effect) {
    draft.cpsGraph = null;
    draft.status = "done";
    return null;
  }
  draft.status = "awaiting-sql";
  return effect
    .map((resume: CpsResumeAction): RuntimeAction => {
      // Plan 115 item 2: a cps-dispatch carries no SQL value and must be
      // forwarded as-is so the reducer's cps-dispatch handler resolves the
      // callee body and manages the call stack. cps-resume carries the SQL
      // result rows from a suspend point.
      if (resume.tag === "cps-dispatch") {
        return {
          tag: "cps-dispatch",
          callee: resume.callee,
          args: resume.args,
          resumePc: resume.resumePc,
        };
      }
      const { dwName, rows } = resume.value as { dwName: string; rows: DWRow[] };
      return { tag: "cps-resume", dwName, rows, pc: resume.pc, varName: resume.var };
    })
    .catch((e): RuntimeAction => ({ tag: "error", message: String(e) }));
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function findBody(
  ast: AstData,
  owner: string,
  event: string,
): ProcEntry | null {
  const key = `${owner}::${event}`.toLowerCase();
  for (const e of ast.events) {
    if (`${e.owner}::${e.name}`.toLowerCase() === key) return e;
  }
  for (const f of ast.functions ?? []) {
    if (`${f.owner}::${f.name}`.toLowerCase() === key) return f;
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

// Plan 115 item 2: resolve a CpsCallProc callee to a body, or null if not found.
//   - "triggerevent" → findEventByName(args[0])
//   - "ancestor::event" → findEventByName(event) ?? findBodyByName(event)
// The body, when present, is run via the tree-walk path (callee bodies rarely
// carry their own cpsGraph, so we pass a tree-walk ProcEntry).
function resolveCalleeBody(
  ast: AstData | null,
  callee: string,
  args: unknown[],
): Located<BodyStmt>[] | null {
  if (!ast) return null;
  if (callee === "triggerevent") {
    const name = String(args[0] ?? "");
    return findEventByName(ast, name);
  }
  // "ancestor::event" — look up the event by name first, then a function body.
  const eventPart = callee.includes("::") ? callee.split("::")[1] ?? "" : callee;
  return findEventByName(ast, eventPart) ?? findBodyByName(ast, eventPart);
}

// Pop the CPS call stack: restore the suspended graph and resume at its PC.
// Also pops the VarEnv frame pushed when the callee was entered.
// If the stack is empty, the whole run is complete.
function popCallStack(
  draft: RuntimeState,
  env: RuntimeEnv,
): Effect<RuntimeAction> | null {
  popFrame(draft.varEnv);
  const frame = draft.callStack.pop();
  if (!frame) {
    draft.cpsGraph = null;
    draft.status = "done";
    return null;
  }
  draft.cpsGraph = frame.graph;
  return stepWithDraft(frame.graph, frame.resumePc, draft, env);
}

// ── Reducer ───────────────────────────────────────────────────────────────────

function runProcEntry(
  draft: RuntimeState,
  entry: ProcEntry,
  env: RuntimeEnv,
): Effect<RuntimeAction> | null {
  // CPS path: use the graph if available and it doesn't require tree-walk patterns.
  if (entry.cpsGraph != null) {
    const graph = loadCpsGraph(entry.cpsGraph);
    if (!graphNeedsTreeWalk(graph)) {
      draft.cpsGraph = graph;
      return stepWithDraft(graph, graph.entry, draft, env);
    }
  }
  // Tree-walk fallback.
  return driveStmts(draft, entry.body, env);
}

function reduce(
  draft: RuntimeState,
  action: RuntimeAction,
  env: RuntimeEnv,
): Effect<RuntimeAction> | null {
  switch (action.tag) {
    case "set-ast":
      draft.ast = action.ast;
      draft.varEnv = makeVarEnv();
      draft.controlValues = {};
      draft.continuation = null;
      draft.treeWalkStack = [];
      draft.cpsGraph = null;
      draft.callStack = [];
      draft.status = "idle";
      draft.error = null;
      return null;

    case "run-event": {
      if (!draft.ast) return null;
      draft.varEnv.locals = [{}];
      draft.treeWalkStack = [];
      for (const [k, v] of Object.entries(PB_GLOBALS)) {
        if (!(k in draft.varEnv.globals)) draft.varEnv.globals[k] = v;
      }
      // Seed window instance variable declarations (e.g. ib_retrieve = true)
      // from the window typeBlock body so BsIf conditions evaluate correctly.
      const windowTb = draft.ast.typeBlocks.find(tb => tb.decl.within == null);
      if (windowTb) {
        for (const s of windowTb.body) {
          const n = s.node;
          if (n.tag === "BsLocalVar" && n.init && !(n.name in draft.varEnv.instance)) {
            draft.varEnv.instance[n.name] = evalExpr(draft.varEnv, n.init);
          }
        }
      }
      draft.status = "running";
      const entry = findBody(draft.ast, action.owner, action.event);
      if (!entry) { draft.status = "done"; return null; }
      return runProcEntry(draft, entry, env);
    }

    case "control-click": {
      if (!draft.ast) return null;
      draft.varEnv.locals = [{}];
      draft.treeWalkStack = [];
      draft.status = "running";
      const entry = findBody(draft.ast, action.controlName, "clicked");
      if (!entry) { draft.status = "done"; return null; }
      return runProcEntry(draft, entry, env);
    }

    case "sql-result": {
      draft.controlValues[action.dwName] = action.rows;
      const cont = draft.continuation;
      draft.continuation = null;
      if (cont?.length) return driveStmts(draft, cont, env);
      return unwindCallStack(draft, env);
    }

    case "cps-resume": {
      draft.controlValues[action.dwName] = action.rows;
      const graph = draft.cpsGraph;
      if (!graph) { draft.status = "done"; return null; }
      return stepWithDraft(graph, action.pc, draft, env);
    }

    case "cps-dispatch": {
      // Push a VarEnv frame and save the suspended CPS graph; run the callee
      // body via the tree-walk path. When the callee finishes, unwindCallStack
      // finds callStack non-empty and calls popCallStack, which pops the frame
      // and resumes the CPS graph at action.resumePc.
      const graph = draft.cpsGraph;
      if (!graph) return null;
      pushFrame(draft.varEnv);
      draft.callStack.push({ graph, resumePc: action.resumePc });
      draft.cpsGraph = null;
      draft.status = "running";
      const body = resolveCalleeBody(draft.ast, action.callee, action.args);
      if (!body) return popCallStack(draft, env);  // callee not found → pop frame + resume
      const entry: ProcEntry = { name: action.callee, owner: "", body, cpsGraph: null };
      return runProcEntry(draft, entry, env);
    }

    case "error":
      draft.status = "error";
      draft.error = action.message;
      return null;
  }
}

export const runtimeReducer: Reducer<RuntimeState, RuntimeAction, RuntimeEnv> = reduce;
