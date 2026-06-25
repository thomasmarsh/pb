// tests/source/SourceViewer.test.tsx — Integration tests for SourceViewer hover/click behaviour.

import { describe, it, expect, afterEach } from "vitest";
import { fireEvent, render, cleanup } from "@solidjs/testing-library";
import { SourceViewer } from "../../app/src/views/components/source/SourceViewer.js";
import { createTestStore } from "../helpers.js";
import type { KnownProcInfo } from "@pb/platform";

afterEach(() => {
  cleanup();
});

const knownProc: KnownProcInfo = {
  name: "f_helper",
  object: "w_test",
  proc_type: "function",
  params: null,
  return_type: null,
  modifiers: null,
  start_line: 1,
  end_line: 5,
  cyclomatic: 2,
};

function renderViewer(opts: {
  lines?: string[];
  knownProcs?: KnownProcInfo[];
  knownObjects?: { name: string; kind: string }[];
} = {}) {
  const { store, captured } = createTestStore();
  render(() => (
    <SourceViewer
      store={store}
      lines={opts.lines ?? ["f_helper()"]}
      procedures={[]}
      knownObjects={opts.knownObjects ?? []}
      knownProcs={opts.knownProcs ?? [knownProc]}
      objectName="w_host"
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
      knownProcs: [],
      knownObjects: [{ name: "w_main", kind: "window" }],
    });
    const span = getObjSpan();
    expect(span).not.toBeNull();
    expect(span?.dataset.linkName).toBe("w_main");
  });

  it("clicking an object span dispatches select with the object name", () => {
    const { captured } = renderViewer({
      lines: ["open(w_main)"],
      knownProcs: [],
      knownObjects: [{ name: "w_main", kind: "window" }],
    });
    fireEvent.click(getObjSpan()!);
    const a = captured.find(
      (x) => x.tag === "objects" && (x as any).action.tag === "select",
    );
    expect(a).toBeDefined();
    expect((a as any).action.name).toBe("w_main");
  });
});
