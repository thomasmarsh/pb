// features/runtime/reducer.ts — CPS-encoded PB interpreter as a TCA reducer.
//
// Each retrieve() call is a labeled suspension point: the reducer fires an
// Effect and resumes when cps-resume arrives after SQL completes.
// Pure statements execute synchronously via runBodySync when no cpsGraph is present.

import { Effect } from "../../core/effect.js";
import type { Reducer } from "../../core/reducer.js";
import type { AstData, DWRow, ProcEntry } from "../../core/interpreter.js";
import type { BodyStmt, Located } from "../../types/ast.generated.js";
import { DW_QUERIES, type SQLResult } from "../../core/dw-queries.js";
import { loadCpsGraph } from "../../core/cps/load.js";
import { step, type CpsResumeAction } from "../../core/cps/runner.js";
import type { CpsGraph } from "../../core/cps/types.js";
import { evalExpr, evalTokenArg } from "../../core/cps/expr.js";
import { type VarEnv, makeVarEnv, writeVar, declareLocal, pushFrame, popFrame } from "../../core/cps/var-env.js";

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
  // CPS-mode graph held for cps-resume; null when idle or after completion.
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
  | { tag: "cps-resume"; dwName: string; rows: DWRow[]; pc: number; varName: string | null }
  // Plan 115 item 2: dispatch a CALL ancestor::event / TriggerEvent to a body
  // found via the AST. Pushes the current graph and resumes at resumePc.
  | { tag: "cps-dispatch"; callee: string; args: unknown[]; resumePc: number }
  | { tag: "error"; message: string };

// ── Synchronous fallback (no CPS graph) ──────────────────────────────────────

// Minimal interpreter for events with no cpsGraph. Handles all pure control
// flow (BsIf/BsFor/BsDo/BsChoose) and assignments. SQL calls are silently
// ignored — only the CPS path (cpsGraph present) fires SQL effects.
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
    // BsReturn, BsPbCall, BsExit, BsContinue, BsAugAssign, BsRaw → no-op in sync mode.
  }
}

// ── CPS execution path ────────────────────────────────────────────────────────

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

// Drive a loaded CPS graph from pc, producing a RuntimeAction Effect on suspend.
// When the graph reaches CpsReturn, checks the call stack for a suspended caller.
function stepWithDraft(
  graph: CpsGraph,
  pc: number,
  draft: RuntimeState,
  env: RuntimeEnv,
): Effect<RuntimeAction> | null {
  const cpsEnv = {
    executeSql: env.executeSql,
    open: (): Effect<unknown> => Effect.none(),
    // Resolve DW name to SQL: first try direct lookup, then resolve via typeBlocks.
    dwNameToSql: (dwName: string): string | null => {
      if (DW_QUERIES[dwName]) return DW_QUERIES[dwName] ?? null;
      const dataobj = findDwDataobject(draft.ast, dwName);
      return dataobj ? (DW_QUERIES[dataobj] ?? null) : null;
    },
  };
  const effect = step(graph, pc, draft.varEnv, cpsEnv);
  if (!effect) {
    draft.cpsGraph = null;
    // Resume suspended caller if present; otherwise the run is complete.
    if (draft.callStack.length > 0) return popCallStack(draft, env);
    draft.status = "done";
    return null;
  }
  draft.status = "awaiting-sql";
  return effect
    .map((resume: CpsResumeAction): RuntimeAction => {
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

// Find any procedure entry by name (ignoring owner), searching all collections.
function findEntryByName(ast: AstData, name: string): ProcEntry | null {
  const n = name.toLowerCase();
  for (const e of ast.events) {
    if (e.name.toLowerCase() === n) return e;
  }
  for (const e of ast.ancestorEvents ?? []) {
    if (e.name.toLowerCase() === n) return e;
  }
  for (const f of ast.functions ?? []) {
    if (f.name.toLowerCase() === n) return f;
  }
  for (const f of ast.ancestorFunctions ?? []) {
    if (f.name.toLowerCase() === n) return f;
  }
  return null;
}

// Resolve a CpsCallProc callee to a full ProcEntry (including cpsGraph if present).
//   - "triggerevent" → find event by args[0] name
//   - "ancestor::event" → find procedure by event name part
function resolveCalleeEntry(
  ast: AstData | null,
  callee: string,
  args: unknown[],
): ProcEntry | null {
  if (!ast) return null;
  if (callee === "triggerevent") {
    return findEntryByName(ast, String(args[0] ?? ""));
  }
  const eventPart = callee.includes("::") ? callee.split("::")[1] ?? "" : callee;
  return findEntryByName(ast, eventPart);
}

// Pop the CPS call stack: restore the suspended graph and resume at its PC.
// Also pops the VarEnv frame pushed when the callee was entered.
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
  if (entry.cpsGraph != null) {
    const graph = loadCpsGraph(entry.cpsGraph);
    draft.cpsGraph = graph;
    return stepWithDraft(graph, graph.entry, draft, env);
  }
  // Sync fallback: handles pure statements; SQL calls are silent no-ops.
  runBodySync(draft.varEnv, entry.body, draft.ast);
  if (draft.callStack.length > 0) return popCallStack(draft, env);
  draft.status = "done";
  return null;
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
      draft.cpsGraph = null;
      draft.callStack = [];
      draft.status = "idle";
      draft.error = null;
      return null;

    case "run-event": {
      if (!draft.ast) return null;
      draft.varEnv.locals = [{}];
      for (const [k, v] of Object.entries(PB_GLOBALS)) {
        if (!(k in draft.varEnv.globals)) draft.varEnv.globals[k] = v;
      }
      // Seed window instance variable declarations from the window typeBlock.
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
      draft.status = "running";
      const entry = findBody(draft.ast, action.controlName, "clicked");
      if (!entry) { draft.status = "done"; return null; }
      return runProcEntry(draft, entry, env);
    }

    case "cps-resume": {
      draft.controlValues[action.dwName] = action.rows;
      const graph = draft.cpsGraph;
      if (!graph) { draft.status = "done"; return null; }
      return stepWithDraft(graph, action.pc, draft, env);
    }

    case "cps-dispatch": {
      // Push a VarEnv frame and save the suspended CPS graph; run the callee.
      // When the callee finishes, popCallStack pops the frame and resumes the
      // CPS graph at action.resumePc.
      const graph = draft.cpsGraph;
      if (!graph) return null;
      pushFrame(draft.varEnv);
      draft.callStack.push({ graph, resumePc: action.resumePc });
      draft.cpsGraph = null;
      draft.status = "running";
      const entry = resolveCalleeEntry(draft.ast, action.callee, action.args);
      if (!entry) return popCallStack(draft, env);
      return runProcEntry(draft, entry, env);
    }

    case "error":
      draft.status = "error";
      draft.error = action.message;
      return null;
  }
}

export const runtimeReducer: Reducer<RuntimeState, RuntimeAction, RuntimeEnv> = reduce;
