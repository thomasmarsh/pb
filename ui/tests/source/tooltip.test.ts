import { describe, it, expect } from "vitest";
import {
  buildObjectTooltip, buildProcTooltip, buildVarTooltip, buildProcBarTooltip,
  renderQuickInfoHeader,
  PROC_COLORS, PROC_BADGE_COLORS,
} from "@pb/platform";
import type { ProcedureInfo, ResolvedCallInfo, ResolvedVarRefInfo, QuickInfoDecl } from "@pb/platform";

function makeCall(overrides: Partial<ResolvedCallInfo> = {}): ResolvedCallInfo {
  return {
    proc_name: "f_caller", to_name: "f_go", call_type: "ExCall", line: 3,
    target_object: "w_test", target_proc: "f_go", kind: "virtual", confidence: "high",
    to_name_start_line: 3, to_name_start_col: 1, to_name_end_line: 3, to_name_end_col: 5,
    target_proc_type: null, target_params: null, target_return_type: null,
    ...overrides,
  };
}

function makeVarRef(overrides: Partial<ResolvedVarRefInfo> = {}): ResolvedVarRefInfo {
  return {
    proc_name: "f_go", line: 1, name: "li_x", access: "read",
    target_object: null, kind: "local", confidence: "high",
    name_start_line: 1, name_start_col: 1, name_end_line: 1, name_end_col: 5,
    declared_type: null,
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

describe("renderQuickInfoHeader", () => {
  it("renders callable shape with return type", () => {
    const decl: QuickInfoDecl = {
      shape: "callable", kindLabel: "Function", kindColor: "#a78bfa",
      name: "of_go", params: "ai_x integer", returnType: "boolean",
    };
    const html = renderQuickInfoHeader(decl);
    expect(html).toContain("‹Function›");
    expect(html).toContain('<span class="qi-name">of_go</span>');
    expect(html).toContain("(ai_x integer)");
    expect(html).toContain("returns");
    expect(html).toContain("boolean");
  });

  it("renders callable shape without return type", () => {
    const decl: QuickInfoDecl = {
      shape: "callable", kindLabel: "Subroutine", kindColor: "#fb923c",
      name: "of_run", params: "", returnType: null,
    };
    const html = renderQuickInfoHeader(decl);
    expect(html).not.toContain("returns");
  });

  it("renders value shape with type", () => {
    const decl: QuickInfoDecl = {
      shape: "value", kindLabel: "Instance", kindColor: "#98c379",
      name: "ii_count", type: "integer",
    };
    const html = renderQuickInfoHeader(decl);
    expect(html).toContain("‹Instance›");
    expect(html).toContain('<span class="qi-name">ii_count</span>');
    expect(html).toContain("(integer)");
  });

  it("renders value shape without type", () => {
    const decl: QuickInfoDecl = {
      shape: "value", kindLabel: "Local", kindColor: "#9cdcfe",
      name: "li_x", type: null,
    };
    const html = renderQuickInfoHeader(decl);
    expect(html).not.toContain("qi-params");
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
  it("uses fallback color when call is undefined", () => {
    const t = buildProcTooltip("f_missing", undefined, undefined);
    expect(t.color).toBe("#a78bfa");
  });

  it("colors by resolution kind when call is known", () => {
    const t = buildProcTooltip("f_go", makeCall({ kind: "static" }), undefined);
    expect(t.color).toBe("#4ec9b0");
  });

  it("includes the resolved target object and proc in html", () => {
    const t = buildProcTooltip("f_go", makeCall({ target_object: "w_test", target_proc: "f_go" }), undefined);
    expect(t.html).toContain("w_test");
    expect(t.html).toContain("f_go");
  });

  it("includes the confidence badge", () => {
    const t = buildProcTooltip("f_go", makeCall({ confidence: "medium" }), undefined);
    expect(t.html).toContain("medium");
  });

  it("includes caller/callee counts when provided", () => {
    const t = buildProcTooltip("f_go", makeCall(), { caller_count: 4, callee_count: 2 });
    expect(t.html).toContain("Callers: 4");
    expect(t.html).toContain("Callees: 2");
  });

  it("renders a PB-style signature header when target signature is present", () => {
    const t = buildProcTooltip("triggerevent", makeCall({
      target_object: "w_test", target_proc: "triggerevent",
      target_proc_type: "function", target_params: "trigevent e", target_return_type: "integer",
    }), undefined);
    expect(t.html).toContain("Function");
    expect(t.html).toContain("(trigevent e)");
    expect(t.html).toContain("returns");
    expect(t.html).toContain("integer");
  });

  it("omits 'returns' for a void/subroutine target", () => {
    const t = buildProcTooltip("of_run", makeCall({
      target_proc_type: "subroutine", target_params: "", target_return_type: null,
    }), undefined);
    expect(t.html).not.toContain("returns");
  });

  it("falls back to the plain header when target signature is absent", () => {
    const t = buildProcTooltip("f_go", makeCall({ target_proc_type: null }), undefined);
    expect(t.html).not.toContain("qi-kind");
    expect(t.html).toContain("virtual");
  });
});

describe("buildVarTooltip", () => {
  it("returns null when ref is undefined", () => {
    expect(buildVarTooltip("li_x", undefined)).toBeNull();
  });

  it("uses parameter color and label for params", () => {
    const t = buildVarTooltip("as_name", makeVarRef({ kind: "param" }));
    expect(t?.color).toBe("#4fc1ff");
    expect(t?.html).toContain("‹Param›");
  });

  it("uses local color and label for locals", () => {
    const t = buildVarTooltip("li_x", makeVarRef({ kind: "local" }));
    expect(t?.color).toBe("#9cdcfe");
    expect(t?.html).toContain("‹Local›");
  });

  it("uses a distinct instance color and label (not the keyword purple)", () => {
    const t = buildVarTooltip("ii_count", makeVarRef({ kind: "instance" }));
    expect(t?.color).toBe("#98c379");
    expect(t?.color).not.toBe("#c586c0");
    expect(t?.html).toContain("‹Instance›");
  });

  it("uses a distinct dw_column color and DW-aware label, distinguishable from builtin_property (Plan 196 Phase 4 item 1)", () => {
    const t = buildVarTooltip("kodfinal", makeVarRef({ kind: "dw_column", declared_type: "string" }));
    expect(t?.color).toBe("#4dd0e1");
    expect(t?.color).not.toBe("#dcdcaa");
    expect(t?.html).toContain("‹DW Column›");
    expect(t?.html).toContain("(string)");
  });

  it("includes target_object when present", () => {
    const t = buildVarTooltip("lo_obj", makeVarRef({ kind: "class", target_object: "w_child" }));
    expect(t?.html).toContain("w_child");
  });

  it("includes declared_type in the header when present", () => {
    const t = buildVarTooltip("li_x", makeVarRef({ kind: "local", declared_type: "long" }));
    expect(t?.html).toContain("(long)");
  });

  it("omits the parenthesized type when declared_type is null", () => {
    const t = buildVarTooltip("ii_count", makeVarRef({ kind: "builtin_property", declared_type: null }));
    expect(t?.html).not.toContain("qi-params");
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
    expect(html).toContain('<span class="qi-name">open</span>');
    expect(html).not.toContain("w_foo · open");
  });
});
