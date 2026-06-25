// tests/features/launch-reducer.test.ts — Tests for the launch reducer.

import { describe, it, expect } from "vitest";
import { Effect } from "@pb/core";
import { createTestStore } from "../test-store.js";
import {
  launchReducer,
  initialLaunchState,
  type LaunchEnv,
} from "../../src/features/launch/reducer.js";
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

const HARDCODED_GLOBALS: Record<string, unknown> = {
  gs_kodxrisi: "0001",
  gs_descxrisi: "Demo",
  gs_app_name: "OpenPay",
  gs_username: "admin",
  gs_version_number: "0.1.1b",
  gs_version_date: "22/12/2005",
  gs_dbver_req: "0.1.1",
  gs_copyright_year: "2005-2006",
  gs_serialnumber: "GPL",
  gs_country: "uk",
  gb_useperm: false,
  gs_kodapp: "openpay",
};

function createMockEnv(astResponse?: AstData, error?: string): LaunchEnv {
  return {
    getObjectAst: () => {
      if (error) {
        return Effect.fromPromise((): Promise<AstData> => Promise.reject(new Error(error)));
      }
      return Effect.send(astResponse ?? makeAst());
    },
  };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("launchReducer", () => {
  describe("load-app", () => {
    it("transitions to loading and returns fetch effect", () => {
      const ast = makeAst();
      const env = createMockEnv(ast);
      const ts = createTestStore(launchReducer, env, initialLaunchState);

      ts.send({ tag: "load-app", sraName: "openpay" }, (s) => {
        s.status = "loading";
        s.appName = "openpay";
        s.error = null;
      });

      // Effect fetches AST and sends app-loaded
      ts.receive({ tag: "app-loaded", ast }, (s) => {
        s.status = "running";
        s.globals = { ...HARDCODED_GLOBALS };
      });

      // app-loaded sends run-app-open
      ts.receive({ tag: "run-app-open", windowName: "w_misth_final_form_create" });

      // run-app-open fetches window AST (mock returns the same ast)
      ts.receive(
        { tag: "window-ast-loaded", windowName: "w_misth_final_form_create", ast },
        (s) => {
          s.status = "done";
          s.windowStack = ["w_misth_final_form_create"];
        },
      );

      ts.assertDrained();
    });

    it("propagates errors from fetch", async () => {
      const env = createMockEnv(undefined, "404 not found");
      const ts = createTestStore(launchReducer, env, initialLaunchState);

      ts.send({ tag: "load-app", sraName: "openpay" }, (s) => {
        s.status = "loading";
        s.appName = "openpay";
      });

      await ts.drain();

      ts.receive({ tag: "launch-error", message: "Error: 404 not found" }, (s) => {
        s.status = "error";
        s.error = "Error: 404 not found";
      });

      ts.assertDrained();
    });
  });

  describe("app-loaded", () => {
    it("seeds globals from hardcoded defaults", () => {
      const ast = makeAst();
      const env: LaunchEnv = { getObjectAst: () => Effect.none() };
      const ts = createTestStore(launchReducer, env, initialLaunchState);

      ts.send({ tag: "app-loaded", ast }, (s) => {
        s.status = "running";
        s.globals = { ...HARDCODED_GLOBALS };
      });

      // app-loaded auto-dispatches run-app-open
      ts.receive({ tag: "run-app-open", windowName: "w_misth_final_form_create" });
      ts.assertDrained();

      // Verify the actual state has the correct globals
      expect(ts.getState().globals.gs_kodxrisi).toBe("0001");
      expect(ts.getState().globals.gs_app_name).toBe("OpenPay");
      expect(ts.getState().globals.gs_version_number).toBe("0.1.1b");
      expect(ts.getState().globals.gs_country).toBe("uk");
      expect(ts.getState().globals.gb_useperm).toBe(false);
    });

    it("declares variables from .sra without overwriting hardcoded defaults", () => {
      const ast = makeAst({
        variables: [
          { name: "gs_host", type: "string", scope: "global" },
          { name: "gs_database", type: "string", scope: "global" },
        ],
      });
      const env: LaunchEnv = { getObjectAst: () => Effect.none() };
      const ts = createTestStore(launchReducer, env, initialLaunchState);

      ts.send({ tag: "app-loaded", ast }, (s) => {
        s.status = "running";
        // gs_host and gs_database are declared as undefined (from .sra vars not in hardcoded)
        s.globals = { ...HARDCODED_GLOBALS, gs_host: undefined, gs_database: undefined };
      });

      ts.receive({ tag: "run-app-open", windowName: "w_misth_final_form_create" });
      ts.assertDrained();

      // Verify: variables from .sra are declared but not overwritten
      expect(ts.getState().globals.gs_host).toBeUndefined();
      expect(ts.getState().globals.gs_database).toBeUndefined();
      // Hardcoded defaults remain
      expect(ts.getState().globals.gs_kodxrisi).toBe("0001");
    });
  });

  describe("run-app-open", () => {
    it("returns effect to fetch window AST", () => {
      const windowAst = makeAst({
        events: [{ name: "open", owner: "w_misth_final_form_create" }],
      });
      const env = createMockEnv(windowAst);
      const ts = createTestStore(launchReducer, env, {
        ...initialLaunchState,
        status: "running",
        appName: "openpay",
      });

      ts.send({ tag: "run-app-open", windowName: "w_misth_final_form_create" });

      ts.receive(
        { tag: "window-ast-loaded", windowName: "w_misth_final_form_create", ast: windowAst },
        (s) => {
          s.status = "done";
          s.windowStack = ["w_misth_final_form_create"];
        },
      );

      ts.assertDrained();
    });

    it("propagates errors from window AST fetch", async () => {
      const env = createMockEnv(undefined, "window not found");
      const ts = createTestStore(launchReducer, env, {
        ...initialLaunchState,
        status: "running",
      });

      ts.send({ tag: "run-app-open", windowName: "w_nonexistent" });

      await ts.drain();

      ts.receive({ tag: "launch-error", message: "Error: window not found" }, (s) => {
        s.status = "error";
        s.error = "Error: window not found";
      });

      ts.assertDrained();
    });
  });

  describe("window-ast-loaded", () => {
    it("pushes window name onto stack and marks done", () => {
      const ast = makeAst();
      const env: LaunchEnv = { getObjectAst: () => Effect.none() };
      const ts = createTestStore(launchReducer, env, {
        ...initialLaunchState,
        status: "running",
      });

      ts.send({ tag: "window-ast-loaded", windowName: "w_misth_final_form_create", ast }, (s) => {
        s.status = "done";
        s.windowStack = ["w_misth_final_form_create"];
      });

      ts.assertDrained();
    });
  });

  describe("close-window", () => {
    it("removes window from stack", () => {
      const env: LaunchEnv = { getObjectAst: () => Effect.none() };
      const ts = createTestStore(launchReducer, env, {
        ...initialLaunchState,
        status: "done",
        windowStack: ["w_misth_final_form_create", "w_child"],
      });

      ts.send({ tag: "close-window", windowName: "w_child" }, (s) => {
        s.windowStack = ["w_misth_final_form_create"];
      });

      ts.assertDrained();
    });
  });

  describe("launch-error", () => {
    it("records error message and status", () => {
      const env: LaunchEnv = { getObjectAst: () => Effect.none() };
      const ts = createTestStore(launchReducer, env, initialLaunchState);

      ts.send({ tag: "launch-error", message: "connection refused" }, (s) => {
        s.status = "error";
        s.error = "connection refused";
      });

      ts.assertDrained();
    });
  });
});
