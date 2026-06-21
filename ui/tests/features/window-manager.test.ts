// tests/features/window-manager.test.ts — Window manager reducer tests.

import { describe, it, expect } from "vitest";
import { windowManagerReducer } from "../../src/features/window-manager/reducer.js";
import { initialWindowManagerState } from "../../src/features/window-manager/initial.js";
import type { WindowManagerState, WindowManagerAction } from "../../src/features/window-manager/types.js";

function reduce(state: WindowManagerState, action: WindowManagerAction): WindowManagerState {
  const draft = structuredClone(state);
  windowManagerReducer(draft, action, undefined);
  return draft;
}

describe("windowManagerReducer", () => {
  it("open-window creates a window at center", () => {
    const s = reduce(initialWindowManagerState, {
      tag: "open-window",
      id: "w1",
      title: "Test Window",
      runtimeWindowName: "w_test",
    });
    expect(s.windows).toHaveLength(1);
    expect(s.windows[0]!.id).toBe("w1");
    expect(s.windows[0]!.title).toBe("Test Window");
    expect(s.windows[0]!.runtimeWindowName).toBe("w_test");
    expect(s.windows[0]!.zIndex).toBe(1);
    expect(s.activeWindowId).toBe("w1");
    expect(s.nextZIndex).toBe(2);
  });

  it("open-window offsets position for stacked windows", () => {
    let s = initialWindowManagerState;
    s = reduce(s, { tag: "open-window", id: "w1", title: "W1", runtimeWindowName: "w1" });
    s = reduce(s, { tag: "open-window", id: "w2", title: "W2", runtimeWindowName: "w2" });
    expect(s.windows[0]!.x).toBeLessThan(s.windows[1]!.x);
    expect(s.windows[0]!.y).toBeLessThan(s.windows[1]!.y);
  });

  it("close-window removes the window", () => {
    let s = initialWindowManagerState;
    s = reduce(s, { tag: "open-window", id: "w1", title: "W1", runtimeWindowName: "w1" });
    s = reduce(s, { tag: "close-window", id: "w1" });
    expect(s.windows).toHaveLength(0);
    expect(s.activeWindowId).toBeNull();
  });

  it("close-window shifts active to top remaining", () => {
    let s = initialWindowManagerState;
    s = reduce(s, { tag: "open-window", id: "w1", title: "W1", runtimeWindowName: "w1" });
    s = reduce(s, { tag: "open-window", id: "w2", title: "W2", runtimeWindowName: "w2" });
    s = reduce(s, { tag: "close-window", id: "w2" });
    expect(s.activeWindowId).toBe("w1");
  });

  it("focus-window brings to front", () => {
    let s = initialWindowManagerState;
    s = reduce(s, { tag: "open-window", id: "w1", title: "W1", runtimeWindowName: "w1" });
    s = reduce(s, { tag: "open-window", id: "w2", title: "W2", runtimeWindowName: "w2" });
    s = reduce(s, { tag: "focus-window", id: "w1" });
    expect(s.activeWindowId).toBe("w1");
    expect(s.windows[0]!.zIndex).toBe(3);
  });

  it("move-window updates position", () => {
    let s = initialWindowManagerState;
    s = reduce(s, { tag: "open-window", id: "w1", title: "W1", runtimeWindowName: "w1" });
    s = reduce(s, { tag: "move-window", id: "w1", x: 100, y: 200 });
    expect(s.windows[0]!.x).toBe(100);
    expect(s.windows[0]!.y).toBe(200);
  });

  it("resize-window enforces minimum size", () => {
    let s = initialWindowManagerState;
    s = reduce(s, { tag: "open-window", id: "w1", title: "W1", runtimeWindowName: "w1" });
    s = reduce(s, { tag: "resize-window", id: "w1", width: 50, height: 30 });
    expect(s.windows[0]!.width).toBe(200);
    expect(s.windows[0]!.height).toBe(150);
  });

  it("minimize-window hides and shifts active", () => {
    let s = initialWindowManagerState;
    s = reduce(s, { tag: "open-window", id: "w1", title: "W1", runtimeWindowName: "w1" });
    s = reduce(s, { tag: "open-window", id: "w2", title: "W2", runtimeWindowName: "w2" });
    s = reduce(s, { tag: "minimize-window", id: "w2" });
    expect(s.windows[1]!.minimized).toBe(true);
    expect(s.activeWindowId).toBe("w1");
  });

  it("maximize-window sets maximized and clears minimized", () => {
    let s = initialWindowManagerState;
    s = reduce(s, { tag: "open-window", id: "w1", title: "W1", runtimeWindowName: "w1" });
    s = reduce(s, { tag: "minimize-window", id: "w1" });
    s = reduce(s, { tag: "maximize-window", id: "w1" });
    expect(s.windows[0]!.maximized).toBe(true);
    expect(s.windows[0]!.minimized).toBe(false);
    expect(s.activeWindowId).toBe("w1");
  });

  it("restore-window clears maximized and minimized", () => {
    let s = initialWindowManagerState;
    s = reduce(s, { tag: "open-window", id: "w1", title: "W1", runtimeWindowName: "w1" });
    s = reduce(s, { tag: "maximize-window", id: "w1" });
    s = reduce(s, { tag: "restore-window", id: "w1" });
    expect(s.windows[0]!.maximized).toBe(false);
    expect(s.windows[0]!.minimized).toBe(false);
  });

  it("close-window with no windows left leaves activeWindowId null", () => {
    const s = reduce(initialWindowManagerState, { tag: "close-window", id: "nonexistent" });
    expect(s.activeWindowId).toBeNull();
    expect(s.windows).toHaveLength(0);
  });
});
