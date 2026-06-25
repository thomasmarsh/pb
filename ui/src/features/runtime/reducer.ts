// features/runtime/reducer.ts — CPS-encoded PB interpreter as a TCA reducer.
//
// Each retrieve() call is a labeled suspension point: the reducer fires an
// Effect and resumes when cps-resume arrives after SQL completes.

import { Effect, type Reducer, type SQLResult } from "@pb/core";
import { loadCpsGraph, step, type CpsResumeAction, evalExpr, type VarEnv, makeVarEnv, pushFrame, popFrame, type AstData, type DWRow, type ProcEntry, type WindowLayout, type CpsGraph } from "@pb/interpreter";

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
  getDwQueries(): Effect<Record<string, string>>;
}

// ── State ─────────────────────────────────────────────────────────────────────

export interface RuntimeState {
  ast: AstData | null;
  layout: WindowLayout | null;
  varEnv: VarEnv;
  controlValues: Record<string, DWRow[]>;
  dwQueries: Record<string, string>;
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
  layout: null,
  varEnv: makeVarEnv(),
  controlValues: {},
  dwQueries: {},
  cpsGraph: null,
  callStack: [],
  status: "idle",
  error: null,
};

// ── Actions ───────────────────────────────────────────────────────────────────

export type RuntimeAction =
  | { tag: "set-ast"; ast: AstData }
  | { tag: "layout-loaded"; layout: WindowLayout | null }
  | { tag: "dw-queries-loaded"; queries: Record<string, string> }
  | { tag: "run-event"; owner: string; event: string; globals?: Record<string, unknown> }
  | { tag: "control-click"; controlName: string }
  | { tag: "cps-resume"; dwName: string; rows: DWRow[]; pc: number; varName: string | null }
  // Plan 115 item 2: dispatch a CALL ancestor::event / TriggerEvent to a body
  // found via the AST. Pushes the current graph and resumes at resumePc.
  | { tag: "cps-dispatch"; callee: string; args: unknown[]; resumePc: number }
  | { tag: "error"; message: string };

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
    // Resolve DW name to SQL: check dwQueries (loaded from DB), then resolve
    // via typeBlocks dataobject property and check again.
    dwNameToSql: (dwName: string): string | null => {
      if (draft.dwQueries[dwName]) return draft.dwQueries[dwName] ?? null;
      const dataobj = findDwDataobject(draft.ast, dwName);
      return dataobj ? (draft.dwQueries[dataobj] ?? null) : null;
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
//   - "super::event"  → look ONLY in ancestorEvents/ancestorFunctions (never recurse into self)
//   - "ancestor::event" → find procedure by event name part in all collections
function resolveCalleeEntry(
  ast: AstData | null,
  callee: string,
  args: unknown[],
): ProcEntry | null {
  if (!ast) return null;
  if (callee === "triggerevent") {
    return findEntryByName(ast, String(args[0] ?? ""));
  }
  if (callee.toLowerCase().startsWith("super::")) {
    const eventPart = callee.split("::")[1] ?? "";
    const n = eventPart.toLowerCase();
    for (const e of ast.ancestorEvents ?? []) {
      if (e.name.toLowerCase() === n) return e;
    }
    for (const f of ast.ancestorFunctions ?? []) {
      if (f.name.toLowerCase() === n) return f;
    }
    return null;
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
  const graph = loadCpsGraph(entry.cpsGraph);
  draft.cpsGraph = graph;
  return stepWithDraft(graph, graph.entry, draft, env);
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
      return env.getDwQueries()
        .map((queries): RuntimeAction => ({ tag: "dw-queries-loaded", queries }))
        .catch((): RuntimeAction => ({ tag: "dw-queries-loaded", queries: {} }));

    case "layout-loaded":
      draft.layout = action.layout;
      return null;

    case "dw-queries-loaded":
      draft.dwQueries = action.queries;
      return null;

    case "run-event": {
      if (!draft.ast) return null;
      draft.varEnv.locals = [{}];
      for (const [k, v] of Object.entries(action.globals ?? PB_GLOBALS)) {
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
