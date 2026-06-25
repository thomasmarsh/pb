// tests/core/dwLayout.test.ts — unit tests for extractDwLayout().

import { describe, it, expect } from "vitest";
import { extractDwLayout } from "../src/dwLayout.js";
import type { DataWindowFile } from "../src/types/ast.js";

// Minimal fixture matching real parser output for dw_misth_zpperiod_list.
const ZPPERIOD_DW: DataWindowFile = {
  release: 9,
  object: { attrs: { units: "0", processing: "1" } },
  table: null,
  groups: [],
  unknowns: [],
  meta: {},
  bands: [
    { kind: { tag: "BkHeader" },  height: 72, color: "536870912", autoSize: false, attrs: {} },
    { kind: { tag: "BkSummary" }, height: 0,  color: "536870912", autoSize: false, attrs: {} },
    { kind: { tag: "BkFooter" },  height: 0,  color: "536870912", autoSize: false, attrs: {} },
    { kind: { tag: "BkDetail" },  height: 72, color: "536870912", autoSize: false, attrs: {} },
  ],
  controls: [
    {
      type: "text", name: "kodperiod_t", band: { tag: "BkHeader" },
      id: null, x: 9, y: 8, width: 146, height: 56,
      visible: true, expression: null, parsedExpression: null,
      format: null, parsedFormat: null, tabSeq: null,
      attrs: { text: "Κωδ.~ttrn(418)" },
    },
    {
      type: "text", name: "descperiod_t", band: { tag: "BkHeader" },
      id: null, x: 165, y: 8, width: 1783, height: 56,
      visible: true, expression: null, parsedExpression: null,
      format: null, parsedFormat: null, tabSeq: null,
      attrs: { text: "Περιγραφή περιόδου~ttrn(523)" },
    },
    {
      type: "column", name: "kodperiod", band: { tag: "BkDetail" },
      id: 1, x: 9, y: 8, width: 146, height: 56,
      visible: true, expression: null, parsedExpression: null,
      format: "[general]", parsedFormat: null, tabSeq: 10,
      attrs: {},
    },
    {
      type: "column", name: "descperiod", band: { tag: "BkDetail" },
      id: 3, x: 165, y: 8, width: 1783, height: 56,
      visible: true, expression: null, parsedExpression: null,
      format: "[general]", parsedFormat: null, tabSeq: 20,
      attrs: {},
    },
  ],
};

describe("extractDwLayout", () => {
  it("sorts bands into display order (header → detail → summary → footer)", () => {
    const lay = extractDwLayout(ZPPERIOD_DW);
    const tags = lay.bands.map((b) => b.tag);
    expect(tags[0]).toBe("BkHeader");
    expect(tags[1]).toBe("BkDetail");
  });

  it("accumulates yOffset correctly across bands", () => {
    const lay = extractDwLayout(ZPPERIOD_DW);
    const header = lay.bands.find((b) => b.tag === "BkHeader")!;
    const detail = lay.bands.find((b) => b.tag === "BkDetail")!;
    expect(header.yOffset).toBe(0);
    expect(detail.yOffset).toBe(72); // header height = 72
  });

  it("strips ~t suffix from text control labels", () => {
    const lay = extractDwLayout(ZPPERIOD_DW);
    const ctrl = lay.controls.find((c) => c.name === "kodperiod_t")!;
    expect(ctrl.label).toBe("Κωδ.");
  });

  it("strips multi-char prefix up to ~t", () => {
    const lay = extractDwLayout(ZPPERIOD_DW);
    const ctrl = lay.controls.find((c) => c.name === "descperiod_t")!;
    expect(ctrl.label).toBe("Περιγραφή περιόδου");
  });

  it("maps column controls to colName with null label", () => {
    const lay = extractDwLayout(ZPPERIOD_DW);
    const ctrl = lay.controls.find((c) => c.name === "kodperiod" && c.type === "column")!;
    expect(ctrl.colName).toBe("kodperiod");
    expect(ctrl.label).toBeNull();
  });

  it("zero-height bands contribute 0 to yOffset", () => {
    const lay = extractDwLayout(ZPPERIOD_DW);
    // summary and footer are both height=0; total = header(72) + detail(72) = 144
    expect(lay.totalHeight).toBe(144);
  });

  it("computes totalWidth from rightmost control edge", () => {
    const lay = extractDwLayout(ZPPERIOD_DW);
    // widest control: x=165, width=1783 → edge = 1948
    expect(lay.totalWidth).toBe(1948);
  });

  it("returns empty layout for DW with no bands or controls", () => {
    const empty: DataWindowFile = {
      ...ZPPERIOD_DW,
      bands: [],
      controls: [],
    };
    const lay = extractDwLayout(empty);
    expect(lay.bands).toHaveLength(0);
    expect(lay.controls).toHaveLength(0);
    expect(lay.totalHeight).toBe(0);
  });
});
