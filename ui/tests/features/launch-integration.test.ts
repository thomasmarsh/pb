// tests/features/launch-integration.test.ts — Integration tests for launch flow
// through the app reducer (launch → window-manager → runtime cascade).

import { describe, it, expect } from "vitest";
import { Effect } from "@pb/core";
import { createTestStore } from "../test-store.js";
import { reducer, initialState, type AppEnv } from "../../app/src/reducer.js";
import type { AstData } from "@pb/interpreter";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeAst(overrides?: Partial<AstData>): AstData {
  return {
    typeBlocks: [],
    events: [],
    functions: [],
    ...overrides,
  };
}

function createAppEnv(astResponses: Record<string, AstData>): AppEnv {
  return {
    getStats: () => Effect.none(),
    getCodeQualityReport: () => Effect.none(),
    getObjects: () => Effect.none(),
    getObject: () => Effect.none(),
    getObjectSource: () => Effect.none(),
    getAllObjects: () => Effect.none(),
    getProcedure: () => Effect.none(),
    getProcedures: () => Effect.none(),
    getWiringDiagram: () => Effect.none(),
    getFootprint: () => Effect.none(),
    getSlice: () => Effect.none(),
    search: () => Effect.none(),
    getDW: () => Effect.none(),
    getDwLayout: () => Effect.none(),
    getObjectLayout: () => Effect.none(),
    getObjectAst: (name: string) => {
      const ast = astResponses[name];
      if (ast) return Effect.send(ast);
      return Effect.fromPromise(
        (): Promise<AstData> => Promise.reject(new Error(`not found: ${name}`)),
      );
    },
    submitDiagramJob: () => Effect.none(),
    pollDiagramJob: () => Effect.none(),
    submitCfgDiagramJob: () => Effect.none(),
    pollCfgDiagramJob: () => Effect.none(),
    getQueries: () => Effect.none(),
    runQuery: () => Effect.none(),
    runSql: () => Effect.none(),
    getExploreTree: () => Effect.none(),
    getExploreProcedure: () => Effect.none(),
    getExploreDatawindow: () => Effect.none(),
    getSchemas: () => Effect.none(),
    getTables: () => Effect.none(),
    getTableDetail: () => Effect.none(),
    getColumnUsage: () => Effect.none(),
    getDecompositionCandidates: () => Effect.none(),
    getErrors: () => Effect.none(),
    getLiveProcedures: () => Effect.none(),
    getDeadVars: () => Effect.none(),
    getDwQueries: () => Effect.none<Record<string, string>>(),
    executeSql: () => Effect.none(),
    navigate: () => Effect.none(),
    pushUrl: () => {},
    loadTheme: () => Effect.send("dark" as never),
    applyTheme: () => Effect.none(),
  };
}

const LAUNCH_GLOBALS: Record<string, unknown> = {
  gs_kodxrisi: "0001", gs_descxrisi: "Demo", gs_app_name: "OpenPay",
  gs_username: "admin", gs_version_number: "0.1.1b", gs_version_date: "22/12/2005",
  gs_dbver_req: "0.1.1", gs_copyright_year: "2005-2006", gs_serialnumber: "GPL",
  gs_country: "uk", gb_useperm: false, gs_kodapp: "openpay",
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const TARGET_WINDOW = "w_misth_final_form_create";

describe("launch integration", () => {
  it("loads .sra, seeds globals, opens target window, and runs open event", () => {
    const sraAst = makeAst();
    // Empty events → findBody returns null → runtime status "done" immediately.
    const windowAst = makeAst({ events: [] });

    const env = createAppEnv({ openpay: sraAst, [TARGET_WINDOW]: windowAst });
    const ts = createTestStore(reducer, env, initialState());

    // 1. Dispatch load-app → effect fires getObjectAst("openpay")
    ts.send({ tag: "launch", action: { tag: "load-app", sraName: "openpay" } }, (s) => {
      s.launch.status = "loading";
      s.launch.appName = "openpay";
    });

    // 2. Receive app-loaded (from effect)
    ts.receive({ tag: "launch", action: { tag: "app-loaded", ast: sraAst } }, (s) => {
      s.launch.status = "running";
      s.launch.globals = { ...LAUNCH_GLOBALS };
    });

    // 3. Receive run-app-open (auto-dispatched by app-loaded → Effect.send)
    ts.receive({ tag: "launch", action: { tag: "run-app-open", windowName: TARGET_WINDOW } });

    // 4. Receive window-ast-loaded (from run-app-open → getObjectAst effect)
    ts.receive({ tag: "launch", action: { tag: "window-ast-loaded", windowName: TARGET_WINDOW, ast: windowAst } }, (s) => {
      s.launch.status = "done";
      s.launch.windowStack = [TARGET_WINDOW];
    });

    // 5. App reducer cascade: open-window + set-ast + run-event + layout-loaded (Effect.none → no layout)
    ts.receive(
      { tag: "windowManager", action: { tag: "open-window", id: expect.any(String), title: TARGET_WINDOW, runtimeWindowName: TARGET_WINDOW } },
    );
    expect(ts.getState().windowManager.windows).toHaveLength(1);

    // windowId is "${windowName}-${Date.now()}" — non-deterministic; skip state callbacks.
    ts.receive({ tag: "runtime", windowId: expect.any(String), action: { tag: "set-ast", ast: windowAst } });
    ts.receive({ tag: "runtime", windowId: expect.any(String), action: { tag: "run-event", owner: TARGET_WINDOW, event: "open", globals: expect.any(Object) } });

    ts.assertDrained();

    const rt = Object.values(ts.getState().runtimes)[0];
    expect(rt?.ast).toEqual(windowAst);
    expect(rt?.status).toBe("done");
  });

  it("handles error when .sra is not found", async () => {
    const env = createAppEnv({});
    const ts = createTestStore(reducer, env, initialState());

    ts.send({ tag: "launch", action: { tag: "load-app", sraName: "missing_app" } }, (s) => {
      s.launch.status = "loading";
      s.launch.appName = "missing_app";
    });

    await ts.drain();

    ts.receive(
      { tag: "launch", action: { tag: "launch-error", message: expect.stringContaining("not found") } },
    );

    expect(ts.getState().launch.status).toBe("error");
    expect(ts.getState().launch.error).toContain("not found");

    ts.assertDrained();
  });
});
