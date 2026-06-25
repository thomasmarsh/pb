// tests/features/runtime-integration.test.ts — Integration tests for the runtime pipeline.
// Tests the full flow: AST → runtimeReducer → controlValues → renderWindow.

import { describe, it, expect } from "vitest";
import { createOpenpayMockEnv } from "../mock-runtime-env.js";
import { renderWindow, makeVarEnv, type AstData } from "@pb/interpreter";
import {
  runtimeReducer,
  initialRuntimeState,
} from "@pb/windowing";
import { createTestStore } from "../test-store.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeAst(overrides?: Partial<AstData>): AstData {
  return {
    typeBlocks: [],
    events: [],
    functions: [],
    ...overrides,
  };
}

function makeAstWithDataobject(controlName: string, dataobject: string): AstData {
  return makeAst({
    typeBlocks: [
      {
        decl: { ancestor: "window", name: "w_test", within: null },
        body: [
          { line: 1, node: { tag: "BsLocalVar", name: "width", type: { tag: "PtPrimitive", contents: "integer" }, mods: [], init: { tag: "ExInt", contents: "2000" } } },
          { line: 2, node: { tag: "BsLocalVar", name: "height", type: { tag: "PtPrimitive", contents: "integer" }, mods: [], init: { tag: "ExInt", contents: "1500" } } },
        ],
      },
      {
        decl: { ancestor: "datawindow", name: controlName, within: "w_test" },
        body: [
          { line: 1, node: { tag: "BsLocalVar", name: "dataobject", type: { tag: "PtPrimitive", contents: "string" }, mods: [], init: { tag: "ExStr", contents: dataobject } } },
        ],
      },
    ],
  });
}

// Minimal CPS graph for a single retrieve() call: CpsSuspend at pc=1, CpsReturn at pc=0.
function makeSingleRetrieveCpsGraph(effect: string) {
  return {
    nodes: [
      { tag: "CpsReturn", value: null },
      {
        tag: "CpsSuspend",
        effect,
        args: [{ tag: "ExLvalue", contents: { segments: [{ name: "gs_kodxrisi", subscript: null }] } }],
        var: null,
        continuation: 0,
      },
    ],
    entry: 1,
    suspensionPoints: [1],
    sourceMap: [],
  };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("runtime integration", () => {
  describe("renderWindow", () => {
    it("extracts layout from typeBlocks", () => {
      const ast = makeAstWithDataobject("dw", "dw_test_list");
      const rendered = renderWindow(ast, {}, makeVarEnv());

      expect(rendered.layout).not.toBeNull();
      expect(rendered.layout!.width).toBe(2000);
      expect(rendered.layout!.height).toBe(1500);
      expect(rendered.controls).toHaveLength(1);
      expect(rendered.controls[0]!.name).toBe("dw");
    });

    it("identifies datawindow controls", () => {
      const ast = makeAstWithDataobject("dw", "dw_test_list");
      const rendered = renderWindow(ast, {}, makeVarEnv());

      expect(rendered.dataWindows).toHaveLength(1);
      expect(rendered.dataWindows[0]!.name).toBe("dw");
      expect(rendered.dataWindows[0]!.dataobject).toBe("dw_test_list");
    });

    it("includes control values in datawindows", () => {
      const ast = makeAstWithDataobject("dw", "dw_test_list");
      const rows = [{ id: 1, name: "test" }, { id: 2, name: "test2" }];
      const rendered = renderWindow(ast, { dw: rows }, makeVarEnv());

      expect(rendered.dataWindows[0]!.rows).toHaveLength(2);
      expect(rendered.dataWindows[0]!.columns).toEqual(["id", "name"]);
    });

    it("returns empty rows when no control values", () => {
      const ast = makeAstWithDataobject("dw", "dw_test_list");
      const rendered = renderWindow(ast, {}, makeVarEnv());

      expect(rendered.dataWindows[0]!.rows).toHaveLength(0);
      expect(rendered.dataWindows[0]!.columns).toHaveLength(0);
    });

    it("passes through variables", () => {
      const ast = makeAst();
      const vars = { gs_kodxrisi: "0001", gs_app_name: "Test" };
      const rendered = renderWindow(ast, {}, { globals: vars, instance: {}, locals: [{}] });

      expect(rendered.variables).toEqual(vars);
    });
  });

  describe("full pipeline: runtime → renderWindow", () => {
    it("w_misth_zpkrat_list: open event triggers SQL via CPS and renders DW", () => {
      const MOCK_ROWS = [
        { kodkrat: "01", kodxrisi: "0001", desckrat: "Category 1", isforos: true, isasf: false, isautoforos: false },
        { kodkrat: "02", kodxrisi: "0001", desckrat: "Category 2", isforos: false, isasf: true, isautoforos: false },
      ];
      const mockEnv = createOpenpayMockEnv();
      const ts = createTestStore(runtimeReducer, mockEnv, {
        ...initialRuntimeState,
        dwQueries: { dw_misth_zpkrat_list: "SELECT kodkrat FROM misth_zpkrat WHERE kodxrisi = ?" },
      });

      const ast = makeAst({
        typeBlocks: [
          { decl: { ancestor: "window", name: "w_misth_zpkrat_list", within: null }, body: [
            { line: 1, node: { tag: "BsLocalVar", name: "width", type: { tag: "PtPrimitive", contents: "integer" }, mods: [], init: { tag: "ExInt", contents: "3000" } } },
            { line: 2, node: { tag: "BsLocalVar", name: "height", type: { tag: "PtPrimitive", contents: "integer" }, mods: [], init: { tag: "ExInt", contents: "2000" } } },
          ]},
          { decl: { ancestor: "datawindow", name: "dw", within: "w_misth_zpkrat_list" }, body: [
            { line: 1, node: { tag: "BsLocalVar", name: "dataobject", type: { tag: "PtPrimitive", contents: "string" }, mods: [], init: { tag: "ExStr", contents: "dw_misth_zpkrat_list" } } },
          ]},
        ],
        events: [{
          name: "open",
          owner: "w_misth_zpkrat_list",
          // CPS graph: retrieve:dw resolves via typeBlocks to dw_misth_zpkrat_list SQL.
          cpsGraph: makeSingleRetrieveCpsGraph("retrieve:dw"),
        }],
      });

      ts.send({ tag: "set-ast", ast });
      ts.send({ tag: "run-event", owner: "w_misth_zpkrat_list", event: "open" });
      ts.receive(
        { tag: "cps-resume", dwName: "dw", rows: MOCK_ROWS, pc: 0, varName: null },
        (s) => { s.controlValues["dw"] = MOCK_ROWS; s.status = "done"; s.cpsGraph = null; },
      );

      // Verify state
      expect(ts.getState().status).toBe("done");
      expect(ts.getState().controlValues["dw"]).toHaveLength(2);

      // Render and verify
      const rendered = renderWindow(ast, ts.getState().controlValues, ts.getState().varEnv);
      expect(rendered.dataWindows).toHaveLength(1);
      expect(rendered.dataWindows[0]!.rows).toHaveLength(2);
      expect(rendered.dataWindows[0]!.columns).toContain("kodkrat");
      expect(rendered.layout!.width).toBe(3000);
    });
  });
});
