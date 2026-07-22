// tests/utils/highlight.test.ts — Unit tests for the PowerScript syntax highlighter.

import { describe, it, expect } from "vitest";
import { highlightPowerScript } from "@pb/platform";
import type { IdentifierLinkContext, ResolvedCallInfo, ResolvedVarRefInfo } from "@pb/platform";

const COMMENT = "#6a9955";

function makeCall(overrides: Partial<ResolvedCallInfo> = {}): ResolvedCallInfo {
  return {
    from_proc: "f_go", to_name: "f_validate", call_type: "ExCall", line: 1,
    target_object: "w_other", target_proc: "f_validate", kind: "virtual", confidence: "high",
    to_name_start_line: 1, to_name_start_col: 1, to_name_end_line: 1, to_name_end_col: 11,
    ...overrides,
  };
}

function makeVarRef(overrides: Partial<ResolvedVarRefInfo> = {}): ResolvedVarRefInfo {
  return {
    from_proc: "f_go", line: 1, name: "li_count", access: "read",
    target_object: null, kind: "local", confidence: "high",
    name_start_line: 1, name_start_col: 1, name_end_line: 1, name_end_col: 9,
    ...overrides,
  };
}

function linkCtx(overrides: Partial<IdentifierLinkContext> = {}): IdentifierLinkContext {
  return {
    baseLine: 1,
    objectMap: new Map(),
    callSpans: new Map(),
    varSpans: new Map(),
    selfName: "self",
    ...overrides,
  };
}

describe("highlightPowerScript — identifier linking", () => {
  it("does not link when no link context is passed", () => {
    const html = highlightPowerScript("f_validate()");
    expect(html).not.toContain("data-link-type");
  });

  it("links a resolved call at its own (line, col)", () => {
    const call = makeCall();
    const link = linkCtx({ callSpans: new Map([["1:1", call]]) });
    const html = highlightPowerScript("f_validate()", link);
    expect(html).toContain('data-link-type="procedure"');
    expect(html).toContain('data-link-name="f_validate"');
    expect(html).toContain('data-link-line="1"');
    expect(html).toContain('data-link-col="1"');
    expect(html).toContain("src-link-proc");
  });

  it("two calls with the same name at different columns resolve independently", () => {
    const a = makeCall({ target_object: "w_a", to_name_start_col: 1 });
    const b = makeCall({ target_object: "w_b", to_name_start_col: 16 });
    const link = linkCtx({ callSpans: new Map([["1:1", a], ["1:16", b]]) });
    const html = highlightPowerScript("f_validate() + f_validate()", link);
    // Both occurrences link (same name), but each keys independently off its own column --
    // the point is the lookup never collides them into one shared target.
    expect((html.match(/data-link-type="procedure"/g) ?? []).length).toBe(2);
  });

  it("does not link an unresolved call", () => {
    const call = makeCall({ kind: "unresolved" });
    const link = linkCtx({ callSpans: new Map([["1:1", call]]) });
    const html = highlightPowerScript("f_validate()", link);
    expect(html).not.toContain("data-link-type");
  });

  it("links a local variable read", () => {
    const ref = makeVarRef({ kind: "local" });
    const link = linkCtx({ varSpans: new Map([["1:1", ref]]) });
    const html = highlightPowerScript("li_count = 1", link);
    expect(html).toContain('data-link-type="var"');
    expect(html).toContain("src-link-var");
  });

  it("links a parameter with the param class", () => {
    const ref = makeVarRef({ kind: "param" });
    const link = linkCtx({ varSpans: new Map([["1:1", ref]]) });
    const html = highlightPowerScript("li_count", link);
    expect(html).toContain("src-link-param");
  });

  it("links an instance var with its own instance class", () => {
    const ref = makeVarRef({ kind: "instance" });
    const link = linkCtx({ varSpans: new Map([["1:1", ref]]) });
    const html = highlightPowerScript("li_count", link);
    expect(html).toContain("src-link-instance");
  });

  it("does not link an unresolved var ref", () => {
    const ref = makeVarRef({ kind: "unresolved" });
    const link = linkCtx({ varSpans: new Map([["1:1", ref]]) });
    const html = highlightPowerScript("li_count", link);
    expect(html).not.toContain("data-link-type");
  });

  it("links a known object by name (fallback for names not covered by a var ref)", () => {
    const link = linkCtx({ objectMap: new Map([["w_main", { name: "w_main", kind: "window" }]]) });
    const html = highlightPowerScript("open(w_main)", link);
    expect(html).toContain('data-link-type="object"');
    expect(html).toContain('data-link-name="w_main"');
    expect(html).toContain("src-link-obj");
  });

  it("skips self-references in the object-link fallback (case-insensitive)", () => {
    const link = linkCtx({
      objectMap: new Map([["w_payment", { name: "w_payment", kind: "window" }]]),
      selfName: "w_payment",
    });
    const html = highlightPowerScript("W_Payment", link);
    expect(html).not.toContain("data-link-type");
  });

  it("still links a global function whose object name equals its own function name", () => {
    // PB global functions are their own PBL member -- the enclosing object name and the
    // function name are the same identifier, so the declaration line's own name must
    // still resolve as a procedure link, not be swallowed by the self-reference guard.
    const call = makeCall({ to_name: "fn_param_maskdate" });
    const link = linkCtx({
      callSpans: new Map([["1:24", call]]),
      selfName: "fn_param_maskdate",
    });
    const html = highlightPowerScript("global function string fn_param_maskdate ()", link);
    expect(html).toContain('data-link-type="procedure"');
  });

  it("skips PB keywords even when they collide with a span key", () => {
    // "if" has no color of its own, so without the PB_KEYWORDS guard it would fall
    // through to the link-lookup branch.
    const call = makeCall({ to_name: "if" });
    const link = linkCtx({ callSpans: new Map([["1:1", call]]) });
    const html = highlightPowerScript("if true then", link);
    expect(html).not.toContain("data-link-type");
  });

  it("does not link words inside comments", () => {
    const call = makeCall();
    const link = linkCtx({ callSpans: new Map([["1:9", call]]) });
    const html = highlightPowerScript("// call f_validate here", link);
    expect(html).not.toContain("data-link-type");
  });
});

describe("highlightPowerScript — multi-line block comments", () => {
  it("colors every line of a multi-line /* */ block as a comment, including keywords/identifiers inside", () => {
    const code = [
      "/*",
      "if as_dwobject then return true",
      "dw_source.DataObject = as_dwobject",
      "*/",
    ].join("\n");
    const lines = highlightPowerScript(code).split("\n");

    expect(lines).toEqual([
      `<span style="color:${COMMENT}">/*</span>`,
      `<span style="color:${COMMENT}">if as_dwobject then return true</span>`,
      `<span style="color:${COMMENT}">dw_source.DataObject = as_dwobject</span>`,
      `<span style="color:${COMMENT}">*/</span>`,
    ]);
  });

  it("resumes normal highlighting on the line after the closing */", () => {
    const code = ["/*", "dead_code = 1", "*/", "ll_records = 1"].join("\n");
    const lines = highlightPowerScript(code).split("\n");

    // The interior line must be entirely comment-colored (this is the line the
    // per-line-only scanner used to miss).
    expect(lines[1]).toBe(`<span style="color:${COMMENT}">dead_code = 1</span>`);
    // The line after the block comment must not be swallowed into a comment span,
    // and its number literal must still be recognized.
    expect(lines[3]).not.toContain(`color:${COMMENT}`);
    expect(lines[3]).toContain(`>1<`);
  });

  it("still highlights a same-line block comment normally (non-regression)", () => {
    const code = "ll_x = 1 /* inline note */ ll_y = 2";
    const html = highlightPowerScript(code);

    expect(html).toContain(`<span style="color:${COMMENT}">/* inline note */</span>`);
    // Code after the inline comment resumes normal highlighting (not comment-colored).
    expect(html.split(`</span>`).pop()).not.toContain(`color:${COMMENT}`);
  });
});
