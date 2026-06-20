// tests/core/layout.test.ts — Unit tests for extractLayout().

import { describe, it, expect } from "vitest";
import { extractLayout } from "../../src/core/layout.js";

// Real typeBlocks fixture from parser output for w_misth_zpperiod_grid.srw.
const ZPPERIOD_TYPE_BLOCKS = [
  {
    decl: { ancestor: "w_pbgrid", name: "w_misth_zpperiod_grid", within: null },
    body: [
      { line: 9,  node: { tag: "BsLocalVar", name: "width",        mods: [], type: { tag: "PtPrimitive", contents: "integer" }, init: { tag: "ExInt", contents: "2245" } } },
      { line: 10, node: { tag: "BsLocalVar", name: "height",       mods: [], type: { tag: "PtPrimitive", contents: "integer" }, init: { tag: "ExInt", contents: "1868" } } },
      { line: 11, node: { tag: "BsLocalVar", name: "title",        mods: [], type: { tag: "PtPrimitive", contents: "string"  }, init: { tag: "ExStr", contents: "title" } } },
      { line: 12, node: { tag: "BsLocalVar", name: "icon",         mods: [], type: { tag: "PtPrimitive", contents: "string"  }, init: { tag: "ExStr", contents: "res\\pinakes.ico" } } },
      { line: 13, node: { tag: "BsLocalVar", name: "is_tablename", mods: [], type: { tag: "PtPrimitive", contents: "string"  }, init: { tag: "ExStr", contents: "misth_zpperiod" } } },
    ],
  },
  {
    decl: { ancestor: "w_pbgrid`dw_main", name: "dw_main", within: "w_misth_zpperiod_grid" },
    body: [
      { line: 102, node: { tag: "BsLocalVar", name: "width",      mods: [], type: { tag: "PtPrimitive", contents: "integer" }, init: { tag: "ExInt", contents: "2213" } } },
      { line: 103, node: { tag: "BsLocalVar", name: "height",     mods: [], type: { tag: "PtPrimitive", contents: "integer" }, init: { tag: "ExInt", contents: "1668" } } },
      { line: 104, node: { tag: "BsLocalVar", name: "dataobject", mods: [], type: { tag: "PtPrimitive", contents: "string"  }, init: { tag: "ExStr", contents: "dw_misth_zpperiod_list" } } },
    ],
  },
];

describe("extractLayout", () => {
  it("returns null for empty typeBlocks", () => {
    expect(extractLayout([])).toBeNull();
  });

  it("extracts window name and type from typeBlocks", () => {
    const layout = extractLayout(ZPPERIOD_TYPE_BLOCKS);
    expect(layout).not.toBeNull();
    expect(layout!.name).toBe("w_misth_zpperiod_grid");
    expect(layout!.type).toBe("w_pbgrid");
  });

  it("extracts window width and height as numbers", () => {
    const layout = extractLayout(ZPPERIOD_TYPE_BLOCKS);
    expect(layout!.width).toBe(2245);
    expect(layout!.height).toBe(1868);
  });

  it("extracts title with surrounding quotes stripped", () => {
    const layout = extractLayout(ZPPERIOD_TYPE_BLOCKS);
    expect(layout!.title).toBe("title");
  });

  it("extracts one control (dw_main)", () => {
    const layout = extractLayout(ZPPERIOD_TYPE_BLOCKS);
    expect(layout!.controls).toHaveLength(1);
    expect(layout!.controls[0]!.name).toBe("dw_main");
    expect(layout!.controls[0]!.parent).toBe("w_misth_zpperiod_grid");
  });

  it("extracts control width and height as numbers", () => {
    const ctrl = extractLayout(ZPPERIOD_TYPE_BLOCKS)!.controls[0]!;
    expect(ctrl.width).toBe(2213);
    expect(ctrl.height).toBe(1668);
  });

  it("extracts control type from backtick ancestor (strips qualifier)", () => {
    const ctrl = extractLayout(ZPPERIOD_TYPE_BLOCKS)!.controls[0]!;
    // ancestor = "w_pbgrid`dw_main" → type = "w_pbgrid"
    expect(ctrl.type).toBe("w_pbgrid");
  });

  it("extracts control string property with quotes stripped", () => {
    const ctrl = extractLayout(ZPPERIOD_TYPE_BLOCKS)!.controls[0]!;
    expect(ctrl.properties["dataobject"]).toBe("dw_misth_zpperiod_list");
  });

  it("defaults x and y to 0 when absent", () => {
    const ctrl = extractLayout(ZPPERIOD_TYPE_BLOCKS)!.controls[0]!;
    expect(ctrl.x).toBe(0);
    expect(ctrl.y).toBe(0);
  });
});
