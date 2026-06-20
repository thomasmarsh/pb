import { describe, it, expect } from "vitest";
import {
  buildObjectTooltip, buildProcTooltip, buildVarTooltip, buildProcBarTooltip,
  PROC_COLORS, PROC_BADGE_COLORS,
} from "../../src/components/source/pure/tooltip.js";
import type { KnownProcInfo, LocalSymbolInfo, ProcedureInfo } from "../../src/types/api.js";

function makeKnownProc(overrides: Partial<KnownProcInfo> = {}): KnownProcInfo {
  return {
    name: "f_go", object: "w_test", proc_type: "function",
    params: "as_name string", return_type: "integer",
    modifiers: null, start_line: 1, end_line: 5, cyclomatic: 3,
    ...overrides,
  };
}

function makeVar(overrides: Partial<LocalSymbolInfo> = {}): LocalSymbolInfo {
  return {
    proc_name: "f_go", var_name: "li_x", raw_type: "integer",
    resolved_kind: "primitive", resolved_target: null, is_parameter: false,
    ...overrides,
  };
}

describe("PROC_COLORS / PROC_BADGE_COLORS", () => {
  it("covers the four proc types", () => {
    for (const t of ["function", "subroutine", "event", "on"]) {
      expect(PROC_COLORS[t]).toBeDefined();
      expect(PROC_BADGE_COLORS[t]).toBeDefined();
    }
  });
});

describe("buildObjectTooltip", () => {
  it("uses datawindow color for datawindow kind", () => {
    const t = buildObjectTooltip("d_orders", { name: "d_orders", kind: "datawindow" });
    expect(t.color).toBe("#56A85D");
    expect(t.html).toContain("datawindow");
  });

  it("uses object color for non-datawindow kind", () => {
    const t = buildObjectTooltip("w_main", { name: "w_main", kind: "window" });
    expect(t.color).toBe("#5B8DD9");
    expect(t.html).toContain("window");
  });

  it("defaults to 'object' kind when obj is undefined", () => {
    const t = buildObjectTooltip("mystery", undefined);
    expect(t.color).toBe("#5B8DD9");
    expect(t.html).toContain("object");
  });

  it("includes linkName in html output", () => {
    const t = buildObjectTooltip("w_payment", { name: "w_payment", kind: "window" });
    expect(t.html).toContain("w_payment");
  });
});

describe("buildProcTooltip", () => {
  it("uses fallback color when proc is undefined", () => {
    const t = buildProcTooltip("f_missing", undefined, undefined);
    expect(t.color).toBe("#a78bfa");
  });

  it("uses proc_type badge color when proc is known", () => {
    const t = buildProcTooltip("f_go", makeKnownProc({ proc_type: "subroutine" }), undefined);
    expect(t.color).toBe(PROC_BADGE_COLORS["subroutine"]);
  });

  it("includes return type, params, and object in html", () => {
    const t = buildProcTooltip("f_go", makeKnownProc(), undefined);
    expect(t.html).toContain("integer");
    expect(t.html).toContain("as_name string");
    expect(t.html).toContain("w_test");
  });

  it("includes cyclomatic complexity badge", () => {
    const t = buildProcTooltip("f_go", makeKnownProc({ cyclomatic: 5 }), undefined);
    expect(t.html).toContain("CC: 5");
  });

  it("includes caller/callee counts when provided", () => {
    const t = buildProcTooltip("f_go", makeKnownProc(), { caller_count: 4, callee_count: 2 });
    expect(t.html).toContain("Callers: 4");
    expect(t.html).toContain("Callees: 2");
  });
});

describe("buildVarTooltip", () => {
  it("returns null when sym is undefined", () => {
    expect(buildVarTooltip("li_x", undefined)).toBeNull();
  });

  it("uses parameter color for params", () => {
    const t = buildVarTooltip("as_name", makeVar({ is_parameter: true }));
    expect(t?.color).toBe("#4fc1ff");
    expect(t?.html).toContain("badge-param");
  });

  it("uses local color for non-params", () => {
    const t = buildVarTooltip("li_x", makeVar({ is_parameter: false }));
    expect(t?.color).toBe("#9cdcfe");
    expect(t?.html).toContain("badge-var");
  });

  it("includes resolved_target when present", () => {
    const t = buildVarTooltip("lo_obj", makeVar({ resolved_target: "w_child", resolved_kind: "object" }));
    expect(t?.html).toContain("w_child");
  });
});

describe("buildProcBarTooltip", () => {
  const p: ProcedureInfo = {
    name: "f_run", proc_type: "function", modifiers: "public",
    params: "ai_x integer", return_type: "boolean",
    start_line: 10, end_line: 25, cyclomatic: 4,
  };

  it("includes proc name and line range", () => {
    const html = buildProcBarTooltip(p, undefined, "#a78bfa", "w_main");
    expect(html).toContain("f_run");
    expect(html).toContain("Lines 10");
    expect(html).toContain("25");
  });

  it("includes CC badge when cyclomatic is set", () => {
    const html = buildProcBarTooltip(p, undefined, "#fff", "w_main");
    expect(html).toContain("CC: 4");
  });

  it("includes caller/callee counts when provided", () => {
    const html = buildProcBarTooltip(p, { caller_count: 6, callee_count: 3 }, "#fff", "w_main");
    expect(html).toContain("Callers: 6");
    expect(html).toContain("Callees: 3");
  });

  it("shows owner prefix when owner differs from viewed object", () => {
    const ev: ProcedureInfo = {
      name: "clicked", proc_type: "event", owner: "cb_cancel",
      modifiers: null, params: null, return_type: null,
      start_line: 10, end_line: 15, cyclomatic: 1,
    };
    const html = buildProcBarTooltip(ev, undefined, "#fff", "w_foo");
    expect(html).toContain("cb_cancel · clicked");
  });

  it("shows bare name when owner equals viewed object", () => {
    const ev: ProcedureInfo = {
      name: "open", proc_type: "event", owner: "w_foo",
      modifiers: null, params: null, return_type: null,
      start_line: 1, end_line: 5, cyclomatic: 1,
    };
    const html = buildProcBarTooltip(ev, undefined, "#fff", "w_foo");
    expect(html).toContain(">open<");
    expect(html).not.toContain("w_foo · open");
  });
});
