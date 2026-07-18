// tests/source/SourceView.test.tsx — Regression tests for the shared source
// viewer used by both the whole-file SourceViewer and the narrowed CodeBlock.
//
// The key invariant: gutter line numbers and highlights come from the SAME
// per-line DOM, so a selected-procedure range (e.g. lines 10–15) must highlight
// exactly those lines and never "extend multiple lines beyond" as the old
// pixel-offset overlay did when PIXELS_PER_LINE drifted from the real height.

import { describe, it, expect } from "vitest";
import { render } from "@solidjs/testing-library";
import { SourceView } from "@pb/platform";

describe("SourceView", () => {
  it("renders a gutter line number per source line", () => {
    const { container } = render(() => <SourceView lines={["a", "b", "c"]} baseLine={10} />);
    const gutter = container.querySelectorAll(".source-gutter-line");
    expect(gutter.length).toBe(3);
    expect(gutter[0]!.textContent).toBe("10");
    expect(gutter[2]!.textContent).toBe("12");
  });

  it("highlights exactly the error line, aligned with the gutter", () => {
    const { container } = render(() => (
      <SourceView lines={["a", "b", "c"]} baseLine={10} highlightLines={new Set([11])} />
    ));
    const gutter = container.querySelectorAll(".source-gutter-line");
    expect(gutter[0]!.classList.contains("source-gutter-line--error")).toBe(false);
    expect(gutter[1]!.classList.contains("source-gutter-line--error")).toBe(true);
    expect(gutter[2]!.classList.contains("source-gutter-line--error")).toBe(false);
  });

  it("highlights the selected-proc range exactly, never beyond it", () => {
    const lines = ["l10", "l11", "l12", "l13", "l14", "l15", "l16"];
    const { container } = render(() => (
      <SourceView lines={lines} baseLine={10} rangeLines={new Set([10, 11, 12, 13, 14, 15])} />
    ));
    const gutter = Array.from(container.querySelectorAll(".source-gutter-line"));
    expect(gutter.length).toBe(7);
    // Exactly the six requested range lines are highlighted — the trailing
    // line 16 must NOT be, proving the highlight cannot drift past the range.
    expect(container.querySelectorAll(".source-gutter-line--range").length).toBe(6);
    const line16 = gutter.find((g) => g.textContent === "16")!;
    expect(line16.classList.contains("source-gutter-line--range")).toBe(false);
    const line10 = gutter.find((g) => g.textContent === "10")!;
    expect(line10.classList.contains("source-gutter-line--range")).toBe(true);
  });

  it("links known procedures into clickable spans", () => {
    const { container } = render(() => (
      <SourceView
        lines={["f_helper()"]}
        knownProcs={[{ name: "f_helper", object: "w_test", proc_type: "function", modifiers: null, params: null, return_type: null, start_line: 1, end_line: 5, cyclomatic: 1 }]}
        objectName="w_host"
      />
    ));
    const span = container.querySelector('[data-link-type="procedure"]') as HTMLElement | null;
    expect(span).not.toBeNull();
    expect(span?.dataset.linkName).toBe("f_helper");
  });

  it("renders a proc bar on exactly the procedure's own lines, never beyond it", () => {
    const lines = Array.from({ length: 10 }, (_, i) => `l${i + 1}`);
    const { container } = render(() => (
      <SourceView
        lines={lines}
        procedures={[
          { name: "f_a", proc_type: "function", modifiers: null, params: null, return_type: null, start_line: 3, end_line: 6, cyclomatic: 1 },
        ]}
      />
    ));
    const gutterLines = Array.from(container.querySelectorAll(".source-gutter-line"));
    const withBar = gutterLines.filter((g) => g.querySelector(".source-proc-bar") != null);
    expect(withBar.length).toBe(4);
    expect(withBar.map((g) => g.getAttribute("data-line"))).toEqual(["3", "4", "5", "6"]);
    // Line 7 (immediately past end_line) and line 10 (last line of file) must
    // never carry a bar — proof the strip can't drift past the procedure.
    const line7 = gutterLines.find((g) => g.getAttribute("data-line") === "7")!;
    const line10 = gutterLines.find((g) => g.getAttribute("data-line") === "10")!;
    expect(line7.querySelector(".source-proc-bar")).toBeNull();
    expect(line10.querySelector(".source-proc-bar")).toBeNull();
  });

  it("dims exactly the lines outside dimLines", () => {
    const { container } = render(() => (
      <SourceView lines={["a", "b", "c"]} dimLines={new Set([2])} />
    ));
    const codeLines = Array.from(container.querySelectorAll(".source-code-line"));
    expect(codeLines[0]!.classList.contains("source-code-line--dim")).toBe(true);
    expect(codeLines[1]!.classList.contains("source-code-line--dim")).toBe(false);
    expect(codeLines[2]!.classList.contains("source-code-line--dim")).toBe(true);
  });

  it("dims nothing when dimLines is null", () => {
    const { container } = render(() => (
      <SourceView lines={["a", "b", "c"]} dimLines={null} />
    ));
    expect(container.querySelectorAll(".source-code-line--dim").length).toBe(0);
  });
});
