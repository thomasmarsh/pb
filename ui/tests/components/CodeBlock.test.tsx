// tests/components/CodeBlock.test.tsx — Tests for CodeBlock and SqlBlock.

import { describe, it, expect } from "vitest";
import { render } from "@solidjs/testing-library";
import { CodeBlock, SqlBlock } from "../../src/components/CodeBlock.js";

describe("CodeBlock", () => {
  it("renders line numbers in gutter", () => {
    const { container } = render(() => (
      <CodeBlock code={"line1\nline2\nline3"} />
    ));
    const gutter = container.querySelectorAll(".source-gutter-line");
    expect(gutter.length).toBe(3);
    expect(gutter[0]!.textContent).toBe("1");
    expect(gutter[1]!.textContent).toBe("2");
    expect(gutter[2]!.textContent).toBe("3");
  });

  it("respects custom baseLine", () => {
    const { container } = render(() => (
      <CodeBlock code={"a\nb"} baseLine={10} />
    ));
    const gutter = container.querySelectorAll(".source-gutter-line");
    expect(gutter[0]!.textContent).toBe("10");
    expect(gutter[1]!.textContent).toBe("11");
  });

  it("renders highlighted code in pre tag", () => {
    const { container } = render(() => (
      <CodeBlock code="SELECT * FROM table" />
    ));
    const pre = container.querySelector(".source-code-area pre");
    expect(pre).not.toBeNull();
    expect(pre!.innerHTML.length).toBeGreaterThan(0);
  });

  it("handles single line code", () => {
    const { container } = render(() => (
      <CodeBlock code="single line" />
    ));
    const gutter = container.querySelectorAll(".source-gutter-line");
    expect(gutter.length).toBe(1);
    expect(gutter[0]!.textContent).toBe("1");
  });
});

describe("SqlBlock", () => {
  it("renders SQL code in pre tag", () => {
    const { container } = render(() => (
      <SqlBlock code="SELECT 1" />
    ));
    const pre = container.querySelector("pre.code-viewer.sql-code");
    expect(pre).not.toBeNull();
    expect(pre!.innerHTML.length).toBeGreaterThan(0);
  });

  it("applies custom style", () => {
    const { container } = render(() => (
      <SqlBlock code="SELECT 1" style={{ "font-size": "11px" }} />
    ));
    const pre = container.querySelector("pre")!;
    expect(pre.style.fontSize).toBe("11px");
  });
});
