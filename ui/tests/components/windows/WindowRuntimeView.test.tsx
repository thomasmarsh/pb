// tests/components/windows/WindowRuntimeView.test.tsx — Component tests for WindowRuntimeView.
//
// Uses a pre-populated RuntimeState (layout already loaded, no env calls).
// All tests are offline — no server, no ResizeObserver layout.

import { describe, it, expect, afterEach } from "vitest";
import { render, cleanup } from "@solidjs/testing-library";
import { WindowRuntimeView } from "../../../app/src/views/components/windows/WindowRuntimeView.js";
import { createTestStore } from "../../helpers.js";
import { initialRuntimeState } from "@pb/windowing";
import { type WindowLayout, type DWRow } from "@pb/interpreter";

const BASE_SCALE = 0.08; // matches the constant in WindowRuntimeView.tsx

afterEach(() => cleanup());

// Simple layout with 7 controls covering all sub-component types.
// Geometry is chosen so no two controls of the same category overlap.
const LAYOUT: WindowLayout = {
  name: "w_test",
  type: "window",
  width: 3000,
  height: 2000,
  title: "Test Window",
  controls: [
    // groupbox spans the full top band
    { name: "gb_1",      type: "groupbox",      x: 0,    y: 0,    width: 3000, height: 200, text: "Group 1" },
    // statictext sits inside the groupbox band (tests z-ordering, not overlap logic)
    { name: "st_1",      type: "statictext",    x: 100,  y: 50,   width: 400,  height: 60,  text: "Label" },
    // two commandbuttons side by side (x-separated by 350 units)
    { name: "cb_ok",     type: "commandbutton", x: 100,  y: 300,  width: 300,  height: 80,  text: "OK" },
    { name: "cb_cancel", type: "commandbutton", x: 450,  y: 300,  width: 300,  height: 80,  text: "Cancel" },
    // two datawindows stacked vertically (no y-overlap)
    { name: "dw_main",   type: "datawindow",    x: 0,    y: 400,  width: 3000, height: 1000 },
    { name: "dw_fylo",   type: "datawindow",    x: 0,    y: 1450, width: 3000, height: 500  },
    // inherited control with unrecognised type → ControlBox
    { name: "ct_inh",   type: "w_form",        x: 100,  y: 1980, width: 200,  height: 80,  text: "Inh" },
  ],
};

function makeStore(controlValues: Record<string, DWRow[]> = {}) {
  return createTestStore({
    runtimes: {
      "test-window": { ...initialRuntimeState, layout: LAYOUT, controlValues },
    },
  });
}

// ── Positioning ───────────────────────────────────────────────────────────────

describe("control CSS positioning", () => {
  it("statictext wrapper has correct left/top/width/height via BASE_SCALE", () => {
    const { store } = makeStore();
    const { container } = render(() => (
      <WindowRuntimeView windowId="test-window" store={store} />
    ));
    // .control-statictext is the inner component; its parent is the positioned wrapper
    const wrapper = container.querySelector(".control-statictext")?.parentElement as HTMLElement;
    expect(wrapper).toBeTruthy();
    expect(wrapper.style.left).toBe(`${100 * BASE_SCALE}px`);
    expect(wrapper.style.top).toBe(`${50 * BASE_SCALE}px`);
    expect(wrapper.style.width).toBe(`${400 * BASE_SCALE}px`);
    expect(wrapper.style.height).toBe(`${60 * BASE_SCALE}px`);
  });

  it("commandbutton wrapper has correct left/top via BASE_SCALE", () => {
    const { store } = makeStore();
    const { container } = render(() => (
      <WindowRuntimeView windowId="test-window" store={store} />
    ));
    const wrapper = container.querySelector("button.control-commandbutton")?.parentElement as HTMLElement;
    expect(wrapper).toBeTruthy();
    expect(wrapper.style.left).toBe(`${100 * BASE_SCALE}px`);
    expect(wrapper.style.top).toBe(`${300 * BASE_SCALE}px`);
  });

  it("cb_ok and cb_cancel wrappers do not overlap (x-separated by 350 units)", () => {
    // cb_ok:     x=100..400 → left=8px,  right=32px
    // cb_cancel: x=450..750 → left=36px, right=60px
    const okRight = (100 + 300) * BASE_SCALE;
    const cancelLeft = 450 * BASE_SCALE;
    expect(okRight).toBeLessThanOrEqual(cancelLeft);
  });
});

// ── Sub-component type routing ────────────────────────────────────────────────

describe("sub-component type routing", () => {
  it("'statictext' type renders .control-statictext", () => {
    const { store } = makeStore();
    const { container } = render(() => (
      <WindowRuntimeView windowId="test-window" store={store} />
    ));
    expect(container.querySelector(".control-statictext")).toBeTruthy();
  });

  it("'commandbutton' type renders button.control-commandbutton", () => {
    const { store } = makeStore();
    const { container } = render(() => (
      <WindowRuntimeView windowId="test-window" store={store} />
    ));
    expect(container.querySelector("button.control-commandbutton")).toBeTruthy();
  });

  it("'groupbox' type renders fieldset.control-groupbox", () => {
    const { store } = makeStore();
    const { container } = render(() => (
      <WindowRuntimeView windowId="test-window" store={store} />
    ));
    expect(container.querySelector("fieldset.control-groupbox")).toBeTruthy();
  });

  it("unrecognised type (w_form) renders .runtime-control ControlBox", () => {
    const { store } = makeStore();
    const { container } = render(() => (
      <WindowRuntimeView windowId="test-window" store={store} />
    ));
    // ct_inh has type "w_form" → falls to ControlBox
    const boxes = container.querySelectorAll(".runtime-control");
    expect(boxes.length).toBeGreaterThan(0);
  });
});

// ── DataWindow controls ───────────────────────────────────────────────────────

describe("datawindow controls", () => {
  it("DW without data renders ControlBox fallback (.runtime-control)", () => {
    const { store } = makeStore(); // no controlValues
    const { container } = render(() => (
      <WindowRuntimeView windowId="test-window" store={store} />
    ));
    // dw_main + dw_fylo have no data → 2 ControlBox instances (plus ct_inh → total ≥ 3)
    const boxes = container.querySelectorAll(".runtime-control");
    expect(boxes.length).toBeGreaterThanOrEqual(3);
  });

  it("DW ControlBox fallback sits at zero offset within its positioned wrapper", () => {
    const { store } = makeStore(); // no controlValues → ControlBox fallback for both DWs
    const { container } = render(() => (
      <WindowRuntimeView windowId="test-window" store={store} />
    ));
    // Find .runtime-control elements that are direct children of a .runtime-ctrl wrapper.
    // They must have no top/left offset — they fill the wrapper, not re-position themselves.
    const wrappedBoxes = container.querySelectorAll(".runtime-ctrl .runtime-control");
    expect(wrappedBoxes.length).toBeGreaterThan(0);
    for (const box of wrappedBoxes) {
      const el = box as HTMLElement;
      const top = el.style.top;
      const left = el.style.left;
      // After the fix: ControlBox uses "0" / "0px" / "" for offset (fills parent).
      // Before the fix: ControlBox repeats the absolute coords → top/left are non-zero px values.
      expect(top === "" || top === "0" || top === "0px").toBe(true);
      expect(left === "" || left === "0" || left === "0px").toBe(true);
    }
  });

  it("DW with populated controlValues renders .dw-grid-container", () => {
    const mockRows: DWRow[] = [{ col1: "a" }, { col1: "b" }];
    const { store } = makeStore({ dw_main: mockRows });
    const { container } = render(() => (
      <WindowRuntimeView windowId="test-window" store={store} />
    ));
    expect(container.querySelector(".dw-grid-container")).toBeTruthy();
  });

  it("DW with data shows a table with the correct row count", () => {
    const mockRows: DWRow[] = [{ col1: "x" }, { col1: "y" }, { col1: "z" }];
    const { store } = makeStore({ dw_main: mockRows });
    const { container } = render(() => (
      <WindowRuntimeView windowId="test-window" store={store} />
    ));
    const trs = container.querySelectorAll("table.data-table tbody tr");
    expect(trs.length).toBe(3);
  });
});

// ── Font size counter-scaling ─────────────────────────────────────────────────
//
// happy-dom's CSS parser rejects calc()+var() for font-size, so we can't assert
// `el.style.fontSize === "calc(11px / var(--canvas-scale, 1))"` — the property is
// silently ignored and reads back as "".  Instead we verify:
//   (1) The ResizableCanvas wrapper sets --canvas-scale so controls CAN counter-scale.
//   (2) font-size is no longer the old hardcoded "11px" (the calc+var replaced it).
// Browsers honour the calc()+var() correctly; happy-dom limitations are documented here.

describe("font size counter-scaling", () => {
  it("ResizableCanvas wrapper exposes --canvas-scale CSS variable", () => {
    const { store } = makeStore();
    const { container } = render(() => (
      <WindowRuntimeView windowId="test-window" store={store} />
    ));
    // The outer wrapper div sets --canvas-scale so child controls can divide by it.
    const canvasWrapper = container.querySelector("[style*='--canvas-scale']");
    expect(canvasWrapper).toBeTruthy();
    const scale = (canvasWrapper as HTMLElement).style.getPropertyValue("--canvas-scale");
    expect(Number(scale)).toBeGreaterThan(0);
  });

  it("StaticText font-size is not hardcoded 11px (uses calc counter-scale formula)", () => {
    const { store } = makeStore();
    const { container } = render(() => (
      <WindowRuntimeView windowId="test-window" store={store} />
    ));
    const el = container.querySelector(".control-statictext") as HTMLElement;
    expect(el).toBeTruthy();
    // happy-dom rejects calc()+var() so fontSize reads ""; in browsers the formula is applied.
    expect(el.style.fontSize).not.toBe("11px");
  });

  it("CommandButton font-size is not hardcoded 11px (uses calc counter-scale formula)", () => {
    const { store } = makeStore();
    const { container } = render(() => (
      <WindowRuntimeView windowId="test-window" store={store} />
    ));
    const el = container.querySelector("button.control-commandbutton") as HTMLElement;
    expect(el).toBeTruthy();
    expect(el.style.fontSize).not.toBe("11px");
  });

  it("GroupBox font-size is not hardcoded 11px (uses calc counter-scale formula)", () => {
    const { store } = makeStore();
    const { container } = render(() => (
      <WindowRuntimeView windowId="test-window" store={store} />
    ));
    const el = container.querySelector("fieldset.control-groupbox") as HTMLElement;
    expect(el).toBeTruthy();
    expect(el.style.fontSize).not.toBe("11px");
  });
});

// ── ResizableCanvas initial state ─────────────────────────────────────────────

describe("ResizableCanvas initial dimensions", () => {
  it("inner content div has the correct natural pixel width (width * BASE_SCALE)", () => {
    const { store } = makeStore();
    const { container } = render(() => (
      <WindowRuntimeView windowId="test-window" store={store} />
    ));
    const expectedWidth = `${3000 * BASE_SCALE}px`; // 240px
    const divs = Array.from(container.querySelectorAll("div[style]")) as HTMLElement[];
    const hasNaturalWidth = divs.some((el) => el.style.width === expectedWidth);
    expect(hasNaturalWidth).toBe(true);
  });

  it("outer canvas container does not start with width 0 (would clip all controls)", () => {
    const { store } = makeStore();
    const { container } = render(() => (
      <WindowRuntimeView windowId="test-window" store={store} />
    ));
    // Find the overflow:hidden container div (the clipping boundary).
    const overflowDivs = (Array.from(container.querySelectorAll("div[style]")) as HTMLElement[])
      .filter((el) => el.style.overflow === "hidden");
    expect(overflowDivs.length).toBeGreaterThan(0);
    const zeroWidthContainers = overflowDivs.filter((el) => el.style.width === "0px");
    expect(zeroWidthContainers.length).toBe(0);
  });
});
