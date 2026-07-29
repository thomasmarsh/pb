// tests/objects/ObjectDetail.test.tsx — Tests for source-first ObjectDetail.

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { fireEvent, render, screen } from "@solidjs/testing-library";
import { ObjectDetail } from "../../app/src/views/features/objects/ObjectDetail.js";
import { createTestStore } from "../helpers.js";
import { initialObjectsState } from "@pb/platform";
import type { ObjectDetailResponse, ObjectSourceResponse } from "@pb/platform";

const baseDetail: ObjectDetailResponse = {
  name: "w_main",
  kind: "powerscript",
  category: "window",
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

function renderObjectDetail(overrides: Partial<ObjectDetailResponse> = {}) {
  const { store, captured } = createTestStore({
    objects: {
      ...initialObjectsState,
      detail: { ...baseDetail, ...overrides },
    },
  });
  render(() => <ObjectDetail store={store} />);
  return { store, captured };
}

describe("ObjectDetail source-first", () => {
  it("does not render a FaceToggle", () => {
    renderObjectDetail();
    expect(document.querySelector(".face-toggle")).toBeNull();
  });

  it("source shown without a tab bar", () => {
    renderObjectDetail();
    expect(document.querySelector(".tab-bar")).toBeNull();
  });

  it("renders AnalysisSummaryBar", () => {
    renderObjectDetail();
    expect(document.querySelector(".analysis-summary-bar")).not.toBeNull();
  });

  it("Callers pill shows count from callers array", () => {
    renderObjectDetail({ callers: ["w_login"] });
    const bar = document.querySelector(".analysis-summary-bar");
    expect(bar?.textContent).toContain("Callers (1)");
  });

  it("Callers pill shows 0 when callers is empty", () => {
    renderObjectDetail({ callers: [] });
    const bar = document.querySelector(".analysis-summary-bar");
    expect(bar?.textContent).toContain("Callers (0)");
  });

  it("clicking Callers pill opens callers panel", () => {
    renderObjectDetail({ callers: ["w_login"] });
    const bar = document.querySelector(".analysis-summary-bar")!;
    const btn = [...bar.querySelectorAll("button")].find((b) =>
      b.textContent?.includes("Callers"),
    )!;
    fireEvent.click(btn);
    expect(document.body.textContent).toContain("w_login");
  });

  it("clicking Callers pill again closes the panel", () => {
    renderObjectDetail({ callers: ["w_login"] });
    const getCallerBtn = () => {
      const bar = document.querySelector(".analysis-summary-bar")!;
      return [...bar.querySelectorAll("button")].find((b) =>
        b.textContent?.includes("Callers"),
      )!;
    };
    fireEvent.click(getCallerBtn());
    fireEvent.click(getCallerBtn());
    // Panel closed — entity card for w_login should not appear
    const cards = document.querySelectorAll(".entity-card");
    const names = [...cards].map((c) => c.textContent ?? "");
    expect(names.some((n) => n.includes("w_login"))).toBe(false);
  });

  it("DWs pill shown when dws_used non-empty", () => {
    renderObjectDetail({ dws_used: ["dw_grid"] });
    const bar = document.querySelector(".analysis-summary-bar");
    expect(bar?.textContent).toContain("DWs (1)");
  });

  it("DWs pill hidden when dws_used empty", () => {
    renderObjectDetail({ dws_used: [] });
    const bar = document.querySelector(".analysis-summary-bar");
    expect(bar?.textContent).not.toContain("DWs");
  });

  it("Tables pill shown when tables_accessed non-empty", () => {
    renderObjectDetail({ tables_accessed: ["orders", "customers"] });
    const bar = document.querySelector(".analysis-summary-bar");
    expect(bar?.textContent).toContain("Tables (2)");
  });

  it("Tables pill hidden when tables_accessed empty", () => {
    renderObjectDetail({ tables_accessed: [] });
    const bar = document.querySelector(".analysis-summary-bar");
    expect(bar?.textContent).not.toContain("Tables");
  });

  it("Metrics pill shown when metrics present", () => {
    renderObjectDetail({
      metrics: {
        object: "w_main", in_degree: 2, out_degree: 3,
        betweenness: 0.1, pagerank: 0.05, max_cyclomatic: 5,
        avg_cyclomatic: 2.5, dit: 1, cbo: 4,
      },
    });
    const bar = document.querySelector(".analysis-summary-bar");
    expect(bar?.textContent).toContain("Metrics");
  });

  it("Metrics pill hidden when metrics null", () => {
    renderObjectDetail({ metrics: null });
    const bar = document.querySelector(".analysis-summary-bar");
    expect(bar?.textContent).not.toContain("Metrics");
  });

  it("callers panel lists caller entity cards after clicking pill", () => {
    renderObjectDetail({ callers: ["w_login", "w_admin"] });
    const bar = document.querySelector(".analysis-summary-bar")!;
    const btn = [...bar.querySelectorAll("button")].find((b) =>
      b.textContent?.includes("Callers"),
    )!;
    fireEvent.click(btn);
    const cards = document.querySelectorAll(".entity-card");
    const names = [...cards].map((c) => c.textContent ?? "");
    expect(names.some((n) => n.includes("w_login"))).toBe(true);
    expect(names.some((n) => n.includes("w_admin"))).toBe(true);
  });

  it("renders error state when detail has error", () => {
    const { store } = createTestStore({
      objects: { ...initialObjectsState, detail: { error: "Not found" } },
    });
    render(() => <ObjectDetail store={store} />);
    expect(document.body.textContent).toContain("Not found");
  });

  it("renders StructuresCard when the object owns inline structures", () => {
    renderObjectDetail({
      structures: [{ name: "s_fish", fields: [{ var_name: "species", var_type: "string", modifiers: null }] }],
    });
    expect(screen.getByText("Structures (1)")).toBeDefined();
    expect(screen.getByText("s_fish (1)")).toBeDefined();
  });

  it("omits StructuresCard when the object owns no inline structures", () => {
    renderObjectDetail({ structures: [] });
    expect(screen.queryByText(/^Structures /)).toBeNull();
  });
});

// ── Proc-scoped panels (right-click in SourceContextMenu) ────────────────────

const sourceDetail: ObjectSourceResponse = {
  file: "app.pbl",
  lines: ["f_helper()"],
  procedures: [],
  knownObjects: [],
  resolvedCalls: [{
    proc_name: "",
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
  }],
  resolvedVarRefs: [],
};

function renderWithSource(overrides: Partial<ObjectDetailResponse> = {}) {
  const { store, captured } = createTestStore({
    objects: {
      ...initialObjectsState,
      detail: { ...baseDetail, ...overrides },
      sourceDetail,
    },
  });
  render(() => <ObjectDetail store={store} />);
  return { store, captured };
}

function getProcSpan(): HTMLElement {
  return document.querySelector('[data-link-type="procedure"]') as HTMLElement;
}

function openContextMenu(): void {
  fireEvent.contextMenu(getProcSpan());
}

function getMenuItem(label: string): HTMLButtonElement {
  return [...document.querySelectorAll(".context-menu button")]
    .find((b) => b.textContent?.includes(label)) as HTMLButtonElement;
}

describe("ObjectDetail proc-scoped panels", () => {
  beforeEach(() => {
    vi.stubGlobal("fetch", () => new Promise(() => {}));
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("right-click on proc identifier enables Find callers menu item", () => {
    renderWithSource();
    const span = getProcSpan();
    expect(span).not.toBeNull();
    openContextMenu();
    const btn = getMenuItem("Find callers");
    expect(btn).toBeDefined();
    expect(btn.hasAttribute("disabled")).toBe(false);
  });

  it("Find callers opens callers panel for the selected proc", () => {
    renderWithSource();
    openContextMenu();
    fireEvent.click(getMenuItem("Find callers"));
    expect(document.body.textContent).toContain("Callers of f_helper");
  });

  it("Find callees opens callees panel for the selected proc", () => {
    renderWithSource();
    openContextMenu();
    fireEvent.click(getMenuItem("Find callees"));
    expect(document.body.textContent).toContain("Callees of f_helper");
  });

  it("View CFG opens CFG panel for the selected proc", () => {
    renderWithSource();
    openContextMenu();
    fireEvent.click(getMenuItem("View CFG"));
    expect(document.body.textContent).toContain("CFG: f_helper");
  });

  it("View taint paths opens taint panel for the selected proc", () => {
    renderWithSource();
    openContextMenu();
    fireEvent.click(getMenuItem("View taint paths"));
    expect(document.body.textContent).toContain("Taint: f_helper");
  });

  it("Escape closes a proc-scoped panel", () => {
    renderWithSource();
    openContextMenu();
    fireEvent.click(getMenuItem("Find callers"));
    expect(document.body.textContent).toContain("Callers of f_helper");
    const container = document.querySelector("[tabindex='-1']") as HTMLElement;
    fireEvent.keyDown(container, { key: "Escape" });
    expect(document.body.textContent).not.toContain("Callers of f_helper");
  });
});
