// tests/objects/ObjectDetail.test.tsx — Tests for ObjectDetail FaceToggle structure.

import { describe, it, expect } from "vitest";
import { fireEvent, render } from "@solidjs/testing-library";
import { ObjectDetail } from "../../src/features/objects/ObjectDetail.js";
import { createTestStore } from "../helpers.js";
import { initialObjectsState } from "../../src/features/objects/reducer.js";
import type { ObjectDetailResponse } from "../../src/types/api.js";

const baseDetail: ObjectDetailResponse = {
  name: "w_main",
  kind: "powerscript",
  file: "app.pbl",
  ancestor: null,
  ancestors: ["w_base"],
  descendants: [],
  callers: ["w_login"],
  callees: ["of_util"],
  procedures: [],
  metrics: null,
  dws_used: ["dw_grid"],
  tables_accessed: ["orders", "customers"],
};

function renderObjectDetail(overrides: Partial<ObjectDetailResponse> = {}, objectFace: "source" | "analysis" = "source") {
  return createTestStore({
    objects: {
      ...initialObjectsState,
      detail: { ...baseDetail, ...overrides },
      objectFace,
    },
  });
}

describe("ObjectDetail face/toggle", () => {
  it("renders Source face active by default", () => {
    const { store } = renderObjectDetail();
    render(() => <ObjectDetail store={store} />);
    const active = document.querySelector(".face-toggle-btn.active");
    expect(active?.textContent).toBe("Source");
  });

  it("renders Analysis face when objectFace is analysis", () => {
    const { store } = renderObjectDetail({}, "analysis");
    render(() => <ObjectDetail store={store} />);
    const active = document.querySelector(".face-toggle-btn.active");
    expect(active?.textContent).toBe("Analysis");
  });

  it("dispatches set-object-face when Analysis button is clicked", () => {
    const { store, captured } = renderObjectDetail();
    render(() => <ObjectDetail store={store} />);
    const analysisBtn = [...document.querySelectorAll(".face-toggle-btn")]
      .find((b) => b.textContent === "Analysis")!;
    fireEvent.click(analysisBtn);
    const faceActions = captured.filter(
      (a) => a.tag === "objects" && a.action.type === "set-object-face",
    );
    expect(faceActions.length).toBeGreaterThanOrEqual(1);
    expect((faceActions[0] as any).action.face).toBe("analysis");
  });

  it("Analysis face shows PhaseGate inline rows for P2, P3, P4", () => {
    const { store } = renderObjectDetail({}, "analysis");
    render(() => <ObjectDetail store={store} />);
    const rows = document.querySelectorAll(".phase-gate-inline");
    expect(rows.length).toBeGreaterThanOrEqual(3);
  });

  it("Analysis face shows DWs Used section with EntityCards", () => {
    const { store } = renderObjectDetail({ dws_used: ["dw_grid", "dw_report"] }, "analysis");
    render(() => <ObjectDetail store={store} />);
    const cards = document.querySelectorAll(".entity-card");
    const names = [...cards].map((c) => c.textContent ?? "");
    expect(names.some((n) => n.includes("dw_grid"))).toBe(true);
    expect(names.some((n) => n.includes("dw_report"))).toBe(true);
  });

  it("Analysis face shows Tables Accessed section with EntityCards", () => {
    const { store } = renderObjectDetail({ tables_accessed: ["orders", "customers"] }, "analysis");
    render(() => <ObjectDetail store={store} />);
    const cards = document.querySelectorAll(".entity-card");
    const names = [...cards].map((c) => c.textContent ?? "");
    expect(names.some((n) => n.includes("orders"))).toBe(true);
    expect(names.some((n) => n.includes("customers"))).toBe(true);
  });

  it("Analysis face shows 'No callers' note when callers is empty", () => {
    const { store } = renderObjectDetail({ callers: [] }, "analysis");
    render(() => <ObjectDetail store={store} />);
    expect(document.body.textContent).toMatch(/no callers/i);
  });

  it("Analysis face shows callers as EntityCards when callers is non-empty", () => {
    const { store } = renderObjectDetail({ callers: ["w_login", "w_admin"] }, "analysis");
    render(() => <ObjectDetail store={store} />);
    const cards = document.querySelectorAll(".entity-card");
    const names = [...cards].map((c) => c.textContent ?? "");
    expect(names.some((n) => n.includes("w_login"))).toBe(true);
  });

  it("Source face does not show PhaseGate rows", () => {
    const { store } = renderObjectDetail({}, "source");
    render(() => <ObjectDetail store={store} />);
    const rows = document.querySelectorAll(".phase-gate-inline");
    expect(rows.length).toBe(0);
  });

  it("Source face shows ProceduresCard when procedures exist", () => {
    const { store } = renderObjectDetail({
      procedures: [{
        object: "w_main", proc_type: "function" as "function", name: "f_open",
        modifiers: null, params: null, return_type: null,
        start_line: 1, end_line: 10, cyclomatic: 1,
      }],
    }, "source");
    render(() => <ObjectDetail store={store} />);
    expect(document.body.textContent).toContain("f_open");
  });

  it("renders error state when detail has error", () => {
    const { store } = createTestStore({
      objects: { ...initialObjectsState, detail: { error: "Not found" } },
    });
    render(() => <ObjectDetail store={store} />);
    expect(document.body.textContent).toContain("Not found");
  });
});
