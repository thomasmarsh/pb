// tests/objects/ObjectDetail.test.tsx — Tests for ObjectDetail tab structure.

import { describe, it, expect, vi } from "vitest";
import { screen, fireEvent, render } from "@solidjs/testing-library";
import { ObjectDetail } from "../../src/features/objects/ObjectDetail.js";
import { createTestStore } from "../helpers.js";

const baseDetail = {
  name: "w_main",
  kind: "powerscript",
  file: "app.pbl",
  ancestors: ["w_base"],
  descendants: [],
  callers: ["w_login"],
  callees: ["of_util"],
  procedures: [],
  metrics: null,
};

describe("ObjectDetail tab structure", () => {
  it("renders Overview tab by default", () => {
    const { store } = createTestStore({
      objects: {
        items: [], total: 0, q: "", kind: "", sort: "name", order: "asc",
        offset: 0, loading: false, detail: baseDetail, sourceDetail: null,
        procedureDetail: null, allObjects: [],
      },
    });
    render(() => <ObjectDetail store={store} />);
    const activeTab = document.querySelector(".tab-btn.active");
    expect(activeTab?.textContent).toBe("Overview");
  });

  it("shows Diagram tab button when object has callers", () => {
    const { store } = createTestStore({
      objects: {
        items: [], total: 0, q: "", kind: "", sort: "name", order: "asc",
        offset: 0, loading: false, detail: baseDetail, sourceDetail: null,
        procedureDetail: null, allObjects: [],
      },
    });
    render(() => <ObjectDetail store={store} />);
    const tabs = [...document.querySelectorAll(".tab-btn")].map((b) => b.textContent);
    expect(tabs).toContain("Diagram");
  });

  it("does not show Diagram tab when no calls or ancestors", () => {
    const { store } = createTestStore({
      objects: {
        items: [], total: 0, q: "", kind: "", sort: "name", order: "asc",
        offset: 0, loading: false,
        detail: { ...baseDetail, callers: [], callees: [], ancestors: [] },
        sourceDetail: null, procedureDetail: null, allObjects: [],
      },
    });
    render(() => <ObjectDetail store={store} />);
    const tabs = [...document.querySelectorAll(".tab-btn")].map((b) => b.textContent);
    expect(tabs).not.toContain("Diagram");
  });

  it("switches to Diagram tab on click", async () => {
    vi.stubGlobal("fetch", () => new Promise(() => {}));
    const { store } = createTestStore({
      objects: {
        items: [], total: 0, q: "", kind: "", sort: "name", order: "asc",
        offset: 0, loading: false, detail: baseDetail, sourceDetail: null,
        procedureDetail: null, allObjects: [],
      },
    });
    render(() => <ObjectDetail store={store} />);
    const diagramBtn = [...document.querySelectorAll(".tab-btn")]
      .find((b) => b.textContent === "Diagram")!;
    fireEvent.click(diagramBtn);
    expect(diagramBtn.classList.contains("active")).toBe(true);
    vi.restoreAllMocks();
  });

  it("shows Source tab only when object has a file", () => {
    const { store } = createTestStore({
      objects: {
        items: [], total: 0, q: "", kind: "", sort: "name", order: "asc",
        offset: 0, loading: false, detail: baseDetail, sourceDetail: null,
        procedureDetail: null, allObjects: [],
      },
    });
    render(() => <ObjectDetail store={store} />);
    const tabs = [...document.querySelectorAll(".tab-btn")].map((b) => b.textContent);
    expect(tabs).toContain("Source");
  });

  it("hides Source tab when object has no file", () => {
    const { store } = createTestStore({
      objects: {
        items: [], total: 0, q: "", kind: "", sort: "name", order: "asc",
        offset: 0, loading: false,
        detail: { ...baseDetail, file: "" },
        sourceDetail: null, procedureDetail: null, allObjects: [],
      },
    });
    render(() => <ObjectDetail store={store} />);
    const tabs = [...document.querySelectorAll(".tab-btn")].map((b) => b.textContent);
    expect(tabs).not.toContain("Source");
  });
});
