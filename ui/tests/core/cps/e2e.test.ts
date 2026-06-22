// tests/core/cps/e2e.test.ts — End-to-end tests for the CPS compile→load→execute loop.
//
// These tests use Haskell-shaped cpsGraph JSON (as emitted by pb-runner) fed through
// loadCpsGraph → step to prove the full pipeline is wired together.

import { describe, it, expect } from "vitest";
import { Effect } from "../../../src/core/effect.js";
import { loadCpsGraph } from "../../../src/core/cps/load.js";
import { step } from "../../../src/core/cps/runner.js";
import type { CpsEnv } from "../../../src/core/cps/types.js";
import { makeVarEnv, flattenVarEnv } from "../../../src/core/cps/var-env.js";
import { createTestStore } from "../../test-store.js";
import {
  runtimeReducer,
  initialRuntimeState,
  PB_GLOBALS,
  type RuntimeState,
} from "../../../src/features/runtime/reducer.js";
import type { AstData } from "../../../src/core/interpreter.js";
import type { SQLResult } from "../../../src/core/dw-queries.js";

// ── Haskell-shaped graph fixtures ─────────────────────────────────────────────
// These match the JSON format emitted by PB.Pipeline.CpsCompile / Serialise.

// Simple assign chain: x = 1; y = 2
const ASSIGN_CHAIN_RAW = {
  nodes: [
    { tag: "CpsReturn" },
    { tag: "CpsAssign", var: "y", rhs: { tag: "ExInt", contents: "2" }, next: 0 },
    { tag: "CpsAssign", var: "x", rhs: { tag: "ExInt", contents: "1" }, next: 1 },
  ],
  entry: 2,
  suspensionPoints: [],
  sourceMap: [[2, 10], [1, 11]] as [number, number][],
};

// If/else: if (true) { x = "then" } else { x = "else" }
const IF_ELSE_RAW = {
  nodes: [
    { tag: "CpsReturn" },
    { tag: "CpsAssign", var: "x", rhs: { tag: "ExStr", contents: "then" }, next: 0 },
    { tag: "CpsAssign", var: "x", rhs: { tag: "ExStr", contents: "else" }, next: 0 },
    { tag: "CpsBranch", cond: { tag: "ExBool", contents: true }, thenPc: 1, elsePc: 2 },
  ],
  entry: 3,
  suspensionPoints: [],
  sourceMap: [],
};

// Single retrieve: dw_period.retrieve(gs_kodxrisi)
// effectName emits "retrieve:dw_period"; args = [ExLvalue gs_kodxrisi]
const RETRIEVE_RAW = {
  nodes: [
    { tag: "CpsReturn" },
    {
      tag: "CpsSuspend",
      effect: "retrieve:dw_period",
      args: [{ tag: "ExLvalue", contents: { segments: [{ name: "gs_kodxrisi", subscript: null }] } }],
      continuation: 0,
    },
  ],
  entry: 1,
  suspensionPoints: [1],
  sourceMap: [],
};

// ── CpsEnv helpers ────────────────────────────────────────────────────────────

const nullEnv: CpsEnv = {
  executeSql: () => Effect.none(),
  open: () => Effect.none(),
};

// ── Tests: direct loadCpsGraph → step ─────────────────────────────────────────

describe("e2e: loadCpsGraph → step", () => {
  it("assign chain executes via loaded cpsGraph", () => {
    const graph = loadCpsGraph(ASSIGN_CHAIN_RAW);
    const varEnv = makeVarEnv();
    const result = step(graph, graph.entry, varEnv, nullEnv);
    expect(result).toBeNull();
    expect(flattenVarEnv(varEnv)).toEqual({ x: 1, y: 2 });
  });

  it("if/else branch selects correct path via cpsGraph", () => {
    const graph = loadCpsGraph(IF_ELSE_RAW);
    const varEnv = makeVarEnv();
    step(graph, graph.entry, varEnv, nullEnv);
    expect(flattenVarEnv(varEnv).x).toBe("then");
  });

  it("retrieve() suspend returns non-null Effect via loaded cpsGraph", () => {
    const MOCK_ROWS = [{ kodperiod: "01" }];
    const sqlResult: SQLResult = { rows: MOCK_ROWS, rowcount: 1, columns: ["kodperiod"] };
    const env: CpsEnv = {
      executeSql: (_sql, _params) => Effect.send(sqlResult),
      open: () => Effect.none(),
      dwNameToSql: (name) => name === "dw_period" ? "SELECT * FROM misth_zpperiod" : null,
    };
    const graph = loadCpsGraph(RETRIEVE_RAW);
    const varEnv = makeVarEnv();
    varEnv.globals["gs_kodxrisi"] = "0001";
    const result = step(graph, graph.entry, varEnv, env);
    expect(result).not.toBeNull();
  });
});

// ── Tests: reducer cps-resume path ────────────────────────────────────────────
// The reducer activates CPS mode when a procEntry carries a cpsGraph.

describe("e2e: reducer CPS path", () => {
  it("assign chain executes via cpsGraph in reducer and transitions to done", () => {
    const ast: AstData = {
      typeBlocks: [],
      events: [
        {
          name: "open",
          owner: "w_test",
          body: [],
          cpsGraph: ASSIGN_CHAIN_RAW,
        },
      ],
    };

    const ts = createTestStore(runtimeReducer, { executeSql: () => Effect.none() }, {
      ...initialRuntimeState,
      ast,
    });

    ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (s) => {
      s.status = "done";
      s.varEnv.globals = { ...PB_GLOBALS };
      s.varEnv.locals[0]!.x = 1;
      s.varEnv.locals[0]!.y = 2;
      s.cpsGraph = null;
    });
    ts.assertDrained();
  });

  it("retrieve() suspend in cpsGraph fires cps-resume action", () => {
    const MOCK_ROWS = [{ kodperiod: "01" }];
    const sqlResult: SQLResult = { rows: MOCK_ROWS, rowcount: 1, columns: ["kodperiod"] };
    const env = { executeSql: () => Effect.send(sqlResult) };

    const ast: AstData = {
      typeBlocks: [],
      events: [
        {
          name: "open",
          owner: "w_test",
          body: [],
          cpsGraph: RETRIEVE_RAW,
        },
      ],
    };

    const graph = loadCpsGraph(RETRIEVE_RAW);
    const ts = createTestStore(runtimeReducer, env, { ...initialRuntimeState, ast });

    ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (s) => {
      s.status = "awaiting-sql";
      s.cpsGraph = graph;
      s.varEnv.globals = { ...PB_GLOBALS };
    });

    ts.receive(
      { tag: "cps-resume", dwName: "dw_period", rows: MOCK_ROWS, pc: 0, varName: null },
      (s: RuntimeState) => {
        s.controlValues = { dw_period: MOCK_ROWS };
        s.status = "done";
        s.cpsGraph = null;
      },
    );

    ts.assertDrained();
  });

  it("missing cpsGraph falls back to tree-walk", () => {
    // Event with body but no cpsGraph → tree-walk path
    const ast: AstData = {
      typeBlocks: [],
      events: [
        {
          name: "open",
          owner: "w_test",
          body: [
            {
              line: 1,
              node: {
                tag: "BsAssign",
                contents: [
                  { segments: [{ name: "x", subscript: null }] },
                  { tag: "ExInt", contents: "99" },
                ],
              },
            },
          ],
          // no cpsGraph — triggers tree-walk
        },
      ],
    };

    const ts = createTestStore(runtimeReducer, { executeSql: () => Effect.none() }, {
      ...initialRuntimeState,
      ast,
    });

    ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (s) => {
      s.status = "done";
      s.varEnv.globals = { ...PB_GLOBALS };
      s.varEnv.locals[0]!.x = 99;
      // continuation and cpsGraph stay null (tree-walk path)
    });
    ts.assertDrained();
  });

  // Plan 115 item 2: CpsCallProc dispatches to an event body via the call stack.
  it("callproc dispatches to event body and resumes via call stack", () => {
    // Graph: [CpsReturn, CpsCallProc "triggerevent" [ExStr "ie_retrieve"] next=0]
    // entry=1. The dispatch target ie_retrieve runs tree-walk and assigns x.
    const CALLPROC_RAW = {
      nodes: [
        { tag: "CpsReturn" },
        {
          tag: "CpsCallProc",
          callee: "triggerevent",
          args: [{ tag: "ExStr", contents: "ie_retrieve" }],
          next: 0,
        },
      ],
      entry: 1,
      suspensionPoints: [],
      sourceMap: [],
    };

    const ast: AstData = {
      typeBlocks: [],
      events: [
        {
          name: "open",
          owner: "w_test",
          body: [],
          cpsGraph: CALLPROC_RAW,
        },
        {
          name: "ie_retrieve",
          owner: "w_test",
          body: [
            {
              line: 1,
              node: {
                tag: "BsAssign",
                contents: [
                  { segments: [{ name: "x", subscript: null }] },
                  { tag: "ExStr", contents: "dispatched" },
                ],
              },
            },
          ],
        },
      ],
    };

    const graph = loadCpsGraph(CALLPROC_RAW);
    const ts = createTestStore(runtimeReducer, { executeSql: () => Effect.none() }, {
      ...initialRuntimeState,
      ast,
    });

    // 1. run-event steps to the callproc node and emits cps-dispatch.
    //    At this point the effect is queued but the dispatch handler hasn't
    //    run, so cpsGraph is still set and callStack is still empty.
    ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (s) => {
      s.status = "awaiting-sql";
      s.cpsGraph = graph;
      s.callStack = [];
      s.varEnv.globals = { ...PB_GLOBALS };
    });

    // 2. cps-dispatch resolves ie_retrieve, runs it tree-walk (assigns x to
    //    the callee's frame), then popCallStack pops that frame and resumes the
    //    graph at pc=0 → CpsReturn → done. x is not visible in the caller's frame.
    ts.receive(
      { tag: "cps-dispatch", callee: "triggerevent", args: ["ie_retrieve"], resumePc: 0 },
      (s) => {
        s.status = "done";
        s.varEnv.globals = { ...PB_GLOBALS };
        s.cpsGraph = null;
        s.callStack = [];
      },
    );

    ts.assertDrained();
  });

  // Plan 115 item 2: unknown callee → cps-dispatch skips and resumes.
  it("callproc with unknown callee pops call stack and resumes", () => {
    const CALLPROC_RAW = {
      nodes: [
        { tag: "CpsReturn" },
        {
          tag: "CpsCallProc",
          callee: "triggerevent",
          args: [{ tag: "ExStr", contents: "no_such_event" }],
          next: 0,
        },
      ],
      entry: 1,
      suspensionPoints: [],
      sourceMap: [],
    };

    const ast: AstData = {
      typeBlocks: [],
      events: [
        {
          name: "open",
          owner: "w_test",
          body: [],
          cpsGraph: CALLPROC_RAW,
        },
        // no ie_retrieve event → resolveCalleeBody returns null
      ],
    };

    const graph = loadCpsGraph(CALLPROC_RAW);
    const ts = createTestStore(runtimeReducer, { executeSql: () => Effect.none() }, {
      ...initialRuntimeState,
      ast,
    });

    ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (s) => {
      s.status = "awaiting-sql";
      s.cpsGraph = graph;
      s.callStack = [];
      s.varEnv.globals = { ...PB_GLOBALS };
    });

    ts.receive(
      { tag: "cps-dispatch", callee: "triggerevent", args: ["no_such_event"], resumePc: 0 },
      (s) => {
        s.status = "done";
        s.cpsGraph = null;
        s.callStack = [];
        s.varEnv.globals = { ...PB_GLOBALS };
      },
    );

    ts.assertDrained();
  });
});
