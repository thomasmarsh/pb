// tests/components/windows/WindowFrame.test.tsx — WindowFrame component tests.

import { describe, it, expect } from "vitest";
import { render, cleanup } from "@solidjs/testing-library";
import { afterEach } from "vitest";
import { WindowFrame } from "../../../src/components/windows/WindowFrame.js";
import { createTestStore } from "../../helpers.js";
import type { ManagedWindow } from "../../../src/features/window-manager/types.js";

afterEach(() => cleanup());

function makeWin(overrides: Partial<ManagedWindow> = {}): ManagedWindow {
  return {
    id: "w1",
    title: "Test Window",
    x: 100,
    y: 100,
    width: 800,
    height: 600,
    zIndex: 1,
    minimized: false,
    maximized: false,
    runtimeWindowName: "w_test",
    ...overrides,
  };
}

describe("WindowFrame", () => {
  it("renders title text", () => {
    const { store } = createTestStore();
    const { getByText } = render(() => (
      <WindowFrame win={makeWin()} isActive={false} store={store}>
        <div>content</div>
      </WindowFrame>
    ));
    expect(getByText("Test Window")).toBeTruthy();
    expect(getByText("content")).toBeTruthy();
  });

  it("applies active class when isActive is true", () => {
    const { store } = createTestStore();
    const { container } = render(() => (
      <WindowFrame win={makeWin()} isActive={true} store={store}>
        <div>content</div>
      </WindowFrame>
    ));
    const el = container.querySelector(".wm-window");
    expect(el?.classList.contains("active")).toBe(true);
  });

  it("applies minimized class", () => {
    const { store } = createTestStore();
    const { container } = render(() => (
      <WindowFrame win={makeWin({ minimized: true })} isActive={false} store={store}>
        <div>content</div>
      </WindowFrame>
    ));
    const el = container.querySelector(".wm-window");
    expect(el?.classList.contains("minimized")).toBe(true);
  });

  it("applies maximized class", () => {
    const { store } = createTestStore();
    const { container } = render(() => (
      <WindowFrame win={makeWin({ maximized: true })} isActive={false} store={store}>
        <div>content</div>
      </WindowFrame>
    ));
    const el = container.querySelector(".wm-window");
    expect(el?.classList.contains("maximized")).toBe(true);
  });

  it("positions window via style", () => {
    const { store } = createTestStore();
    const { container } = render(() => (
      <WindowFrame win={makeWin({ x: 200, y: 300, width: 640, height: 480 })} isActive={false} store={store}>
        <div>content</div>
      </WindowFrame>
    ));
    const el = container.querySelector(".wm-window") as HTMLElement;
    expect(el.style.left).toBe("200px");
    expect(el.style.top).toBe("300px");
    expect(el.style.width).toBe("640px");
    expect(el.style.height).toBe("480px");
  });
});
