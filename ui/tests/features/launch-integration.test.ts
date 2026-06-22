// tests/features/launch-integration.test.ts — Integration tests for launch flow
// through the app reducer (launch → window-manager → runtime cascade).

import { describe, it, expect } from "vitest";
import { Effect } from "../../src/core/effect.js";
import { createTestStore } from "../test-store.js";
import { reducer, initialState, type AppEnv } from "../../src/features/app/reducer.js";
import { PB_GLOBALS } from "../../src/features/runtime/reducer.js";
import type { AstData } from "../../src/core/interpreter.js";

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
    getObjects: () => Effect.none(),
    getObject: () => Effect.none(),
    getObjectSource: () => Effect.none(),
    getAllObjects: () => Effect.none(),
    getProcedure: () => Effect.none(),
    getProcedures: () => Effect.none(),
    search: () => Effect.none(),
    getDW: () => Effect.none(),
    getDwLayout: () => Effect.none(),
    getObjectAst: (name: string) => {
      const ast = astResponses[name];
      if (ast) return Effect.send(ast);
      return Effect.fromPromise(
        (): Promise<AstData> => Promise.reject(new Error(`not found: ${name}`)),
      );
    },
    getDiagram: () => Effect.none(),
    getQueries: () => Effect.none(),
    runQuery: () => Effect.none(),
    runSql: () => Effect.none(),
    getExploreTree: () => Effect.none(),
    getExploreProcedure: () => Effect.none(),
    getExploreDatawindow: () => Effect.none(),
    getTables: () => Effect.none(),
    getTableDetail: () => Effect.none(),
    getErrors: () => Effect.none(),
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

describe("launch integration", () => {
  it("loads .sra, seeds globals, opens w_app, and runs open event", () => {
    const sraAst = makeAst();
    const wAppAst = makeAst({
      events: [{ name: "open", owner: "w_app", body: [] }],
    });

    const env = createAppEnv({ openpay: sraAst, w_app: wAppAst });
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
    ts.receive({ tag: "launch", action: { tag: "run-app-open", windowName: "w_app" } });

    // 4. Receive window-ast-loaded (from run-app-open → getObjectAst("w_app") effect)
    ts.receive({ tag: "launch", action: { tag: "window-ast-loaded", windowName: "w_app", ast: wAppAst } }, (s) => {
      s.launch.status = "done";
      s.launch.windowStack = ["w_app"];
    });

    // 5. App reducer cascade dispatches: open-window, set-ast, run-event
    ts.receive(
      { tag: "windowManager", action: { tag: "open-window", id: expect.any(String), title: "w_app", runtimeWindowName: "w_app" } },
    );
    expect(ts.getState().windowManager.windows).toHaveLength(1);

    ts.receive({ tag: "runtime", action: { tag: "set-ast", ast: wAppAst } }, (s) => {
      s.runtime.ast = wAppAst;
      s.runtime.variables = {};
    });

    ts.receive({ tag: "runtime", action: { tag: "run-event", owner: "w_app", event: "open" } }, (s) => {
      s.runtime.status = "done";
      s.runtime.variables = { ...PB_GLOBALS };
    });

    ts.assertDrained();
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
