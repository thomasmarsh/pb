// tests/objects/SourceContextMenu.test.tsx — Tests for the right-click context menu on source identifiers.

import { describe, it, expect, vi, afterEach } from "vitest";
import { fireEvent, render, cleanup } from "@solidjs/testing-library";
import { SourceContextMenu } from "../../src/components/detail/SourceContextMenu.js";
import type { ContextMenuTarget, ContextActions } from "../../src/components/detail/SourceContextMenu.js";
import { createTestStore } from "../helpers.js";

afterEach(() => {
  cleanup();
});

const procTarget: ContextMenuTarget = {
  linkType: "procedure",
  linkName: "f_validate",
  x: 100,
  y: 200,
  sourceLine: 15,
  callerCount: 3,
  calleeCount: 2,
};

const objectTarget: ContextMenuTarget = {
  linkType: "object",
  linkName: "w_main",
  x: 50,
  y: 80,
  sourceLine: 5,
};

function renderMenu(
  target: ContextMenuTarget | null,
  contextActions?: ContextActions,
  onClose?: () => void,
) {
  const { store, captured } = createTestStore();
  render(() => (
    <SourceContextMenu
      target={target}
      store={store}
      objectName="w_payment"
      contextActions={contextActions}
      onClose={onClose ?? (() => {})}
    />
  ));
  return { store, captured };
}

describe("SourceContextMenu", () => {
  it("hidden when target is null", () => {
    renderMenu(null);
    expect(document.querySelector(".context-menu")).toBeNull();
  });

  it("renders when target is a procedure", () => {
    renderMenu(procTarget);
    expect(document.querySelector(".context-menu")).not.toBeNull();
  });

  it("renders when target is an object", () => {
    renderMenu(objectTarget);
    expect(document.querySelector(".context-menu")).not.toBeNull();
  });

  it("Go to definition for proc dispatches proc-select", () => {
    const { captured } = renderMenu(procTarget);
    const btn = [...document.querySelectorAll(".context-menu button")]
      .find((b) => b.textContent?.includes("Go to definition"))!;
    expect(btn).toBeDefined();
    fireEvent.click(btn);
    expect(captured.some((a) =>
      a.tag === "objects" && "action" in a &&
      (a as any).action.tag === "proc-select" &&
      (a as any).action.procName === "f_validate"
    )).toBe(true);
  });

  it("Go to definition for object dispatches select", () => {
    const { captured } = renderMenu(objectTarget);
    const btn = [...document.querySelectorAll(".context-menu button")]
      .find((b) => b.textContent?.includes("Go to definition"))!;
    fireEvent.click(btn);
    expect(captured.some((a) =>
      a.tag === "objects" && "action" in a &&
      (a as any).action.tag === "select" &&
      (a as any).action.name === "w_main"
    )).toBe(true);
  });

  it("Find callers shows count in label", () => {
    renderMenu(procTarget, { onFindCallers: () => {} });
    const btn = [...document.querySelectorAll(".context-menu button")]
      .find((b) => b.textContent?.includes("Find callers"))!;
    expect(btn).toBeDefined();
    expect(btn.textContent).toContain("3");
  });

  it("Find callers disabled when no onFindCallers callback", () => {
    renderMenu(procTarget);
    const btn = [...document.querySelectorAll(".context-menu button")]
      .find((b) => b.textContent?.includes("Find callers"))!;
    expect(btn).toBeDefined();
    expect(btn.hasAttribute("disabled")).toBe(true);
  });

  it("Find callers calls callback and closes menu", () => {
    const onFindCallers = vi.fn();
    const onClose = vi.fn();
    renderMenu(procTarget, { onFindCallers }, onClose);
    const btn = [...document.querySelectorAll(".context-menu button")]
      .find((b) => b.textContent?.includes("Find callers"))!;
    fireEvent.click(btn);
    expect(onFindCallers).toHaveBeenCalledWith("f_validate");
    expect(onClose).toHaveBeenCalled();
  });

  it("Find callees disabled when no onFindCallees callback", () => {
    renderMenu(procTarget);
    const btn = [...document.querySelectorAll(".context-menu button")]
      .find((b) => b.textContent?.includes("Find callees"))!;
    expect(btn).toBeDefined();
    expect(btn.hasAttribute("disabled")).toBe(true);
  });

  it("View CFG disabled when no onViewCfg callback", () => {
    renderMenu(procTarget);
    const btn = [...document.querySelectorAll(".context-menu button")]
      .find((b) => b.textContent?.includes("View CFG"))!;
    expect(btn).toBeDefined();
    expect(btn.hasAttribute("disabled")).toBe(true);
  });

  it("proc-only items not shown for object target", () => {
    renderMenu(objectTarget);
    const allText = document.querySelector(".context-menu")?.textContent ?? "";
    expect(allText).not.toContain("Find callers");
    expect(allText).not.toContain("View CFG");
    expect(allText).not.toContain("backward slice");
  });

  it("Backward slice dispatches go-slice with correct proc and line", () => {
    const { captured } = renderMenu(procTarget);
    const btn = [...document.querySelectorAll(".context-menu button")]
      .find((b) => b.textContent?.toLowerCase().includes("backward slice"))!;
    expect(btn).toBeDefined();
    fireEvent.click(btn);
    expect(captured.some((a) =>
      a.tag === "objects" && "action" in a &&
      (a as any).action.tag === "go-slice" &&
      (a as any).action.proc === "f_validate" &&
      (a as any).action.line === 15
    )).toBe(true);
  });

  it("Escape key calls onClose", () => {
    const onClose = vi.fn();
    renderMenu(procTarget, {}, onClose);
    fireEvent.keyDown(document, { key: "Escape" });
    expect(onClose).toHaveBeenCalled();
  });
});
