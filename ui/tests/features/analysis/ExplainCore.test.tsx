// tests/features/analysis/ExplainCore.test.tsx — Component tests for the
// Explain split pane's hover/pin highlighting and region-ref jump chips
// (Plan 222 Phase 4).

import { describe, it, expect, vi } from "vitest";
import { fireEvent, render } from "@solidjs/testing-library";
import { ExplainCore } from "../../../app/src/views/features/analysis/ExplainCore.js";
import { createTestStore } from "../../helpers.js";
import type { ExplainPseudocodeResponse } from "@pb/platform";

const PSEUDOCODE: ExplainPseudocodeResponse = {
  declaredSig: null,
  rootRegion: "region_0",
  rootSig: { inputs: [], outputs: [], effects: [] },
  regions: {
    region_0: [
      { tag: "PAssign", contents: ["ls_x", null, null, null, 1], stmtText: "ls_x = 1" },
      { tag: "PRegionRef", contents: ["region_1", [3, 4], { inputs: [], outputs: [], effects: [] }], stmtText: "-> region_1" },
    ],
    region_1: [
      { tag: "PReturn", contents: [null, 3], stmtText: "return true" },
    ],
  },
  sourceOriginal: "ls_x = 1\nls_y = 2\nif ls_x then\n  return true\nend if",
  procStartLine: 1,
};

function setup() {
  const { store } = createTestStore({
    explainPseudocodes: {
      "w_obj::uf_save": { object: "w_obj", proc: "uf_save", data: PSEUDOCODE },
    },
  });
  const result = render(() => (
    <ExplainCore object="w_obj" proc="uf_save" store={store} onGoto={() => {}} />
  ));
  return result;
}

function setupWith(overrides: { declaredSig: ExplainPseudocodeResponse["declaredSig"] }) {
  const pc: ExplainPseudocodeResponse = { ...PSEUDOCODE, declaredSig: overrides.declaredSig };
  const { store } = createTestStore({
    explainPseudocodes: {
      "w_obj::uf_save": { object: "w_obj", proc: "uf_save", data: pc },
    },
  });
  const result = render(() => (
    <ExplainCore object="w_obj" proc="uf_save" store={store} onGoto={() => {}} />
  ));
  return result;
}

describe("ExplainCore", () => {
  it("hovering a statement highlights and dims its own source line", () => {
    const { container } = setup();
    const stmtRow = [...container.querySelectorAll(".explain-stmt")].find((el) => el.textContent === "ls_x = 1")!;
    fireEvent.mouseEnter(stmtRow);

    const line1 = container.querySelector('.source-code-line[data-line="1"]')!;
    const line2 = container.querySelector('.source-code-line[data-line="2"]')!;
    expect(line1.classList.contains("source-code-line--error")).toBe(true);
    expect(line1.classList.contains("source-code-line--dim")).toBe(false);
    expect(line2.classList.contains("source-code-line--dim")).toBe(true);
  });

  it("mouse-out reverts highlighting to nothing when no statement is pinned", () => {
    const { container } = setup();
    const stmtRow = [...container.querySelectorAll(".explain-stmt")].find((el) => el.textContent === "ls_x = 1")!;
    fireEvent.mouseEnter(stmtRow);
    fireEvent.mouseLeave(stmtRow);

    const line1 = container.querySelector('.source-code-line[data-line="1"]')!;
    expect(line1.classList.contains("source-code-line--error")).toBe(false);
    expect(line1.classList.contains("source-code-line--dim")).toBe(false);
  });

  it("clicking a statement pins it; mouse-out then keeps the pinned highlight", () => {
    const { container } = setup();
    const stmtRow = [...container.querySelectorAll(".explain-stmt")].find((el) => el.textContent === "ls_x = 1")!;
    fireEvent.mouseEnter(stmtRow);
    fireEvent.click(stmtRow);
    fireEvent.mouseLeave(stmtRow);

    const line1 = container.querySelector('.source-code-line[data-line="1"]')!;
    expect(line1.classList.contains("source-code-line--error")).toBe(true);
  });

  it("hovering a statement highlights but does not auto-scroll the source pane; pinning it does", () => {
    const { container } = setup();
    const scrollSpy = vi.spyOn(Element.prototype, "scrollIntoView").mockImplementation(() => {});
    const stmtRow = [...container.querySelectorAll(".explain-stmt")].find((el) => el.textContent === "ls_x = 1")!;

    fireEvent.mouseEnter(stmtRow);
    expect(scrollSpy).not.toHaveBeenCalled();

    fireEvent.click(stmtRow);
    expect(scrollSpy).toHaveBeenCalled();
  });

  it("renders a region-ref as a call (name(args)) using region@N, not region_N", () => {
    const { container } = setup();
    const chip = container.querySelector(".explain-stmt--region-ref")!;
    expect(chip.textContent).toBe("region@3()");
  });

  it("renders a closing '}' row in each region card whose inferred sig was emitted", () => {
    const { container } = setup();
    // The fixture has both region_0 (root, with rootSig) and region_1 (with a
    // ref sig) — both should gain a trailing '}' matching the opened header.
    const cards = container.querySelectorAll(".explain-region-card");
    expect(cards.length).toBe(2);
    for (const card of cards) {
      const headers = [...card.querySelectorAll(".explain-region-header")];
      const lastHeader = headers[headers.length - 1];
      expect(lastHeader?.textContent).toBe("}");
    }
  });

  it("clicking a region-ref chip flashes its target region card", () => {
    const { container } = setup();
    const chip = container.querySelector(".explain-stmt--region-ref")!;
    fireEvent.click(chip);

    const targetCard = container.querySelector("#region-card-region_1")!;
    expect(targetCard.classList.contains("explain-region-card--flash")).toBe(true);
  });

  it("root card with FnSig declaredSig shows the declared return type capitalized in the header", () => {
    const { container } = setupWith({
      declaredSig: {
        Left: {
          mods: [], returnType: "string", returnTypeSpan: null, name: "uf_save",
          params: [], throws: null, library: null, aliasFor: null,
        },
      },
    });
    const rootCard = container.querySelector("#region-card-region_0")!;
    const headers = [...rootCard.querySelectorAll(".explain-region-header")];
    const inferredHeader = headers.find((h) => h.textContent?.startsWith("function region_0"))!;
    expect(inferredHeader.textContent).toBe("function region_0() -> String {");
  });

  it("root card with SubSig declaredSig (event handler) falls through to the inferred signature", () => {
    const { container } = setupWith({
      declaredSig: {
        Right: {
          mods: [], name: "uf_close", params: [],
          throws: null, library: null, aliasFor: null,
        },
      },
    });
    const rootCard = container.querySelector("#region-card-region_0")!;
    const headers = [...rootCard.querySelectorAll(".explain-region-header")];
    const inferredHeader = headers.find((h) => h.textContent?.startsWith("function region_0"))!;
    expect(inferredHeader.textContent).toBe("function region_0() -> () {");
  });

  it("cut (non-root) region card does not show the declared return type even when declaredSig is a FnSig", () => {
    const { container } = setupWith({
      declaredSig: {
        Left: {
          mods: [], returnType: "string", returnTypeSpan: null, name: "uf_save",
          params: [], throws: null, library: null, aliasFor: null,
        },
      },
    });
    const cutCard = container.querySelector("#region-card-region_1")!;
    const headers = [...cutCard.querySelectorAll(".explain-region-header")];
    const inferredHeader = headers.find((h) => h.textContent?.startsWith("function region@3"))!;
    expect(inferredHeader.textContent).toBe("function region@3() -> () {");
  });
});
