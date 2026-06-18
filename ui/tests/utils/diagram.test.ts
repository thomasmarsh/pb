// tests/utils/diagram.test.ts — Unit tests for diagram utilities.

import { describe, it, expect } from "vitest";
import { parsePbUrl, diagramUrl } from "../../src/utils/diagram.js";

describe("parsePbUrl", () => {
  it("parses object URL", () => {
    expect(parsePbUrl("pb://object/w_main")).toEqual({
      kind: "object",
      name: "w_main",
      meta: {},
    });
  });

  it("parses table URL with metadata", () => {
    expect(parsePbUrl("pb://table/customer#op=SELECT,cc=5")).toEqual({
      kind: "table",
      name: "customer",
      meta: { op: "SELECT", cc: "5" },
    });
  });

  it("returns null for non-pb URL", () => {
    expect(parsePbUrl("http://example.com")).toBeNull();
  });

  it("returns null for null", () => {
    expect(parsePbUrl(null)).toBeNull();
  });

  it("returns null for pb:// with no slash after kind", () => {
    expect(parsePbUrl("pb://object")).toBeNull();
  });
});

describe("diagramUrl", () => {
  it("omits query string when params empty", () => {
    expect(diagramUrl("heatmap")).toBe("/api/diagram/heatmap");
    expect(diagramUrl("heatmap", {})).toBe("/api/diagram/heatmap");
  });

  it("encodes non-empty params", () => {
    expect(diagramUrl("calls", { focal: "w_main", depth: 2 })).toBe(
      "/api/diagram/calls?focal=w_main&depth=2",
    );
  });

  it("omits empty-string param values", () => {
    expect(diagramUrl("dw-tables", { table: "" })).toBe(
      "/api/diagram/dw-tables",
    );
  });
});
