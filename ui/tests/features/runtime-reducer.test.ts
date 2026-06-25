// tests/features/runtime-reducer.test.ts — Tests for the runtime reducer.

import { describe, it } from "vitest";
import { Effect } from "@pb/core";
import { createTestStore } from "../test-store.js";
import {
  runtimeReducer,
  initialRuntimeState,
  PB_GLOBALS,
  type RuntimeEnv,
} from "@pb/windowing";
import type { AstData } from "@pb/interpreter";

// ── Helpers ───────────────────────────────────────────────────────────────────

const nullEnv: RuntimeEnv = {
  getDwQueries: () => Effect.none(),
  executeSql: () => Effect.none(),
};

function makeAst(overrides?: Partial<AstData>): AstData {
  return {
    typeBlocks: [],
    events: [],
    functions: [],
    ...overrides,
  };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("runtimeReducer", () => {
  describe("set-ast", () => {
    it("stores ast and resets execution state", () => {
      const ast = makeAst();
      const ts = createTestStore(runtimeReducer, nullEnv, {
        ...initialRuntimeState,
        varEnv: { globals: { x: 1 }, instance: {}, locals: [{}] },
        status: "done",
      });
      ts.send({ tag: "set-ast", ast }, (s) => {
        s.ast = ast;
        s.varEnv = { globals: {}, instance: {}, locals: [{}] };
        s.controlValues = {};
        s.status = "idle";
        s.error = null;
      });
      ts.assertDrained();
    });
  });

  describe("run-event / no-op cases", () => {
    it("is a no-op when ast is null", () => {
      const ts = createTestStore(runtimeReducer, nullEnv, initialRuntimeState);
      ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (_s) => {});
      ts.assertDrained();
    });
  });

  describe("run-event / globals seeding", () => {
    it("seeds PB_GLOBALS into variables before executing", () => {
      // Use a non-existent event so findBody returns null → done without cpsGraph.
      const ast = makeAst({ events: [] });
      const ts = createTestStore(runtimeReducer, nullEnv, { ...initialRuntimeState, ast });
      ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (s) => {
        s.status = "done";
        s.varEnv.globals = { ...PB_GLOBALS };
      });
      ts.assertDrained();
    });

    it("does not overwrite variables already set before run-event", () => {
      const ast = makeAst({ events: [] });
      const ts = createTestStore(runtimeReducer, nullEnv, {
        ...initialRuntimeState,
        ast,
        varEnv: { globals: { gs_kodxrisi: "9999" } as Record<string, unknown>, instance: {}, locals: [{}] },
      });
      ts.send({ tag: "run-event", owner: "w_test", event: "open" }, (s) => {
        s.status = "done";
        s.varEnv.globals = { gs_kodxrisi: "9999", gs_app_name: "OpenPay", gs_username: "admin" };
      });
      ts.assertDrained();
    });
  });

  describe("error", () => {
    it("records error message and status", () => {
      const ts = createTestStore(runtimeReducer, nullEnv, initialRuntimeState);
      ts.send({ tag: "error", message: "boom" }, (s) => {
        s.status = "error";
        s.error = "boom";
      });
      ts.assertDrained();
    });
  });
});
