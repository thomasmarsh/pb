// tests/source/SourceViewer.test.tsx — Integration tests for SourceViewer hover/click behaviour.

import { describe, it, expect, afterEach } from "vitest";
import { fireEvent, render, cleanup } from "@solidjs/testing-library";
import { SourceViewer } from "../../app/src/views/components/source/SourceViewer.js";
import { createTestStore } from "../helpers.js";
import type { ProcedureInfo, ResolvedCallInfo } from "@pb/platform";

afterEach(() => {
  cleanup();
});

const resolvedCall: ResolvedCallInfo = {
  proc_name: "f_current",
  to_name: "f_helper",
  call_type: "ExCall",
  line: 1,
  target_object: "w_test",
  target_proc: "f_helper",
  kind: "virtual",
  confidence: "high",
  to_name_start_line: 1,
  to_name_start_col: 1,
  to_name_end_line: 1,
  to_name_end_col: 9,
  target_proc_type: null,
  target_params: null,
  target_return_type: null,
};

function renderViewer(opts: {
  lines?: string[];
  procedures?: ProcedureInfo[];
  resolvedCalls?: ResolvedCallInfo[];
  knownObjects?: { name: string; kind: string }[];
  sliceHighlight?: { lines: Set<number>; label: string } | null;
  onClearSliceHighlight?: () => void;
} = {}) {
  const { store, captured } = createTestStore();
  render(() => (
    <SourceViewer
      store={store}
      lines={opts.lines ?? ["f_helper()"]}
      procedures={opts.procedures ?? []}
      knownObjects={opts.knownObjects ?? []}
      resolvedCalls={opts.resolvedCalls ?? [resolvedCall]}
      objectName="w_host"
      sliceHighlight={opts.sliceHighlight}
      onClearSliceHighlight={opts.onClearSliceHighlight}
    />
  ));
  return { captured };
}

function getProcSpan(): HTMLElement | null {
  return document.querySelector('[data-link-type="procedure"]');
}

function getObjSpan(): HTMLElement | null {
  return document.querySelector('[data-link-type="object"]');
}

describe("SourceViewer", () => {
  it("renders a linkable proc span for a known procedure", () => {
    renderViewer();
    const span = getProcSpan();
    expect(span).not.toBeNull();
    expect(span?.dataset.linkName).toBe("f_helper");
  });

  it("hovering a proc span shows a tooltip containing the proc name", () => {
    renderViewer();
    fireEvent.mouseOver(getProcSpan()!, { clientX: 100, clientY: 100 });
    const tooltip = document.querySelector(".source-proc-tooltip.visible");
    expect(tooltip).not.toBeNull();
    expect(tooltip?.innerHTML).toContain("f_helper");
  });

  it("tooltip disappears after mousing out of a proc span", () => {
    renderViewer();
    fireEvent.mouseOver(getProcSpan()!, { clientX: 100, clientY: 100 });
    expect(document.querySelector(".source-proc-tooltip.visible")).not.toBeNull();
    fireEvent.mouseOut(getProcSpan()!);
    expect(document.querySelector(".source-proc-tooltip.visible")).toBeNull();
  });

  it("clicking a proc span dispatches proc-select with the resolved object", () => {
    const { captured } = renderViewer();
    fireEvent.click(getProcSpan()!);
    const a = captured.find(
      (x) => x.tag === "objects" && (x as any).action.tag === "proc-select",
    );
    expect(a).toBeDefined();
    expect((a as any).action.procName).toBe("f_helper");
    expect((a as any).action.objectName).toBe("w_test");
  });

  it("renders a linkable object span for a known object", () => {
    renderViewer({
      lines: ["open(w_main)"],
      resolvedCalls: [],
      knownObjects: [{ name: "w_main", kind: "window" }],
    });
    const span = getObjSpan();
    expect(span).not.toBeNull();
    expect(span?.dataset.linkName).toBe("w_main");
  });

  it("clicking an object span dispatches select with the object name", () => {
    const { captured } = renderViewer({
      lines: ["open(w_main)"],
      resolvedCalls: [],
      knownObjects: [{ name: "w_main", kind: "window" }],
    });
    fireEvent.click(getObjSpan()!);
    const a = captured.find(
      (x) => x.tag === "objects" && (x as any).action.tag === "select",
    );
    expect(a).toBeDefined();
    expect((a as any).action.name).toBe("w_main");
  });

  it("renders no dimmed lines or banner when sliceHighlight is absent", () => {
    renderViewer();
    expect(document.querySelector(".source-slice-banner")).toBeNull();
    expect(document.querySelector(".source-code-line--dim")).toBeNull();
  });

  it("renders the slice banner and dims every non-highlighted line", () => {
    renderViewer({
      lines: ["a", "b", "c", "d", "e"],
      sliceHighlight: { lines: new Set([3]), label: "Backward slice — 1 statement" },
    });
    const banner = document.querySelector(".source-slice-banner");
    expect(banner).not.toBeNull();
    expect(banner?.textContent).toContain("Backward slice — 1 statement");
    // Lines 1, 2, 4, 5 are dimmed around the single highlighted line 3.
    expect(document.querySelectorAll(".source-code-line--dim").length).toBe(4);
  });

  it("dims every line when nothing is highlighted but sliceHighlight is set", () => {
    renderViewer({
      lines: ["a", "b", "c"],
      sliceHighlight: { lines: new Set(), label: "Backward slice — 0 statements" },
    });
    expect(document.querySelectorAll(".source-code-line--dim").length).toBe(3);
  });

  it("Clear button calls onClearSliceHighlight", () => {
    let cleared = false;
    renderViewer({
      lines: ["a", "b", "c"],
      sliceHighlight: { lines: new Set([2]), label: "Backward slice" },
      onClearSliceHighlight: () => { cleared = true; },
    });
    const btn = document.querySelector(".source-slice-banner button")!;
    fireEvent.click(btn);
    expect(cleared).toBe(true);
  });

  const viewedProc: ProcedureInfo = {
    name: "f_current", proc_type: "function", modifiers: null, params: null,
    return_type: null, start_line: 1, end_line: 5, cyclomatic: 1,
  };

  it("right-clicking a call to a procedure in a different object still slices the procedure enclosing the clicked line", () => {
    const { captured } = renderViewer({ procedures: [viewedProc] });
    fireEvent.contextMenu(getProcSpan()!, { clientX: 100, clientY: 0 });
    const btn = [...document.querySelectorAll(".context-menu button")]
      .find((b) => b.textContent?.includes("Generate backward slice"))!;
    expect(btn).toBeDefined();
    fireEvent.click(btn);
    const a = captured.find(
      (x) => x.tag === "objects" && (x as any).action.tag === "go-slice",
    );
    expect(a).toBeDefined();
    // f_helper (the clicked span) is owned by w_test — the slice must target
    // f_current/w_host (the procedure actually enclosing the clicked line
    // in the currently viewed object), not the clicked identifier's own target.
    expect((a as any).action.object).toBe("w_host");
    expect((a as any).action.proc).toBe("f_current");
    expect((a as any).action.line).toBe(1);
  });

  it("backward slice menu items are absent when no procedure encloses the clicked line", () => {
    renderViewer({ procedures: [] });
    fireEvent.contextMenu(getProcSpan()!, { clientX: 100, clientY: 0 });
    const allText = document.querySelector(".context-menu")?.textContent ?? "";
    expect(allText).not.toContain("backward slice");
  });
});
