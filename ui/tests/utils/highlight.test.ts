// tests/utils/highlight.test.ts — Unit tests for the PowerScript syntax highlighter.

import { describe, it, expect } from "vitest";
import { highlightPowerScript } from "@pb/platform";

const COMMENT = "#6a9955";

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
