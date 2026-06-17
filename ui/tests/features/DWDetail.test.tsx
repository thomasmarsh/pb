// tests/features/DWDetail.test.tsx — Tests for DWDetail tab structure.

import { describe, it, expect, vi } from "vitest";
import { fireEvent, render } from "@solidjs/testing-library";
import { DWDetail } from "../../src/features/datawindows/DataWindows.js";
import { createTestStore } from "../helpers.js";
import type { DwDetailResponse } from "../../src/types/api.js";

function makeDw(overrides: Partial<DwDetailResponse> = {}): DwDetailResponse {
  return {
    name: "dw_orders",
    file: "w_order.srd",
    controls: [
      { control_name: "col_id", control_type: "column", band: "detail", x: 10, y: 20, width: 80, height: 24, expression: null, tab_seq: null, source_line: null },
    ],
    retrieve_tables: ["orders", "customers"],
    retrieve_columns: [{ column_fqn: "orders.id", table_name: "orders", column_name: "id" }],
    retrieve_where: [{ idx: 1, exp1: "orders.id", op: "=", exp2: ":arg_id", logic: "" }],
    arguments: [{ arg_name: "arg_id", arg_type: "long" }],
    source: "select 1 from orders",
    ...overrides,
  };
}

function renderDWDetail(dwDetail: DwDetailResponse | { error: string } | null) {
  const { store } = createTestStore({
    datawindows: {
      items: [], total: 0, q: "", loading: false, dwDetail,
    },
  });
  return render(() => <DWDetail store={store} />);
}

describe("DWDetail tab structure", () => {
  it("shows Overview tab by default", () => {
    renderDWDetail(makeDw());
    const activeTab = document.querySelector(".tab-btn.active");
    expect(activeTab?.textContent).toBe("Overview");
  });

  it("shows Controls tab when DW has controls", () => {
    renderDWDetail(makeDw());
    const tabs = [...document.querySelectorAll(".tab-btn")].map((b) => b.textContent ?? "");
    expect(tabs.some((t) => t.startsWith("Controls"))).toBe(true);
  });

  it("shows Diagram tab when DW has retrieve_tables", () => {
    renderDWDetail(makeDw());
    const tabs = [...document.querySelectorAll(".tab-btn")].map((b) => b.textContent);
    expect(tabs).toContain("Diagram");
  });

  it("shows Source tab when DW has source", () => {
    renderDWDetail(makeDw());
    const tabs = [...document.querySelectorAll(".tab-btn")].map((b) => b.textContent);
    expect(tabs).toContain("Source");
  });

  it("hides Controls tab when DW has no controls", () => {
    renderDWDetail(makeDw({ controls: [] }));
    const tabs = [...document.querySelectorAll(".tab-btn")].map((b) => b.textContent ?? "");
    expect(tabs.some((t) => t.startsWith("Controls"))).toBe(false);
  });

  it("hides Diagram tab when DW has no retrieve_tables", () => {
    renderDWDetail(makeDw({ retrieve_tables: [] }));
    const tabs = [...document.querySelectorAll(".tab-btn")].map((b) => b.textContent);
    expect(tabs).not.toContain("Diagram");
  });

  it("hides Source tab when DW has no source", () => {
    renderDWDetail(makeDw({ source: null }));
    const tabs = [...document.querySelectorAll(".tab-btn")].map((b) => b.textContent);
    expect(tabs).not.toContain("Source");
  });

  it("shows InlineDiagram container in Diagram tab", async () => {
    vi.stubGlobal("fetch", () => new Promise(() => {}));
    renderDWDetail(makeDw());
    const diagramBtn = [...document.querySelectorAll(".tab-btn")]
      .find((b) => b.textContent === "Diagram")!;
    fireEvent.click(diagramBtn);
    expect(diagramBtn.classList.contains("active")).toBe(true);
    expect(document.querySelectorAll(".diagram-container").length).toBeGreaterThanOrEqual(1);
    vi.restoreAllMocks();
  });

  it("switches between tabs correctly", () => {
    renderDWDetail(makeDw());
    const controlsBtn = [...document.querySelectorAll(".tab-btn")]
      .find((b) => b.textContent?.startsWith("Controls"))!;
    fireEvent.click(controlsBtn);
    expect(controlsBtn.classList.contains("active")).toBe(true);

    const overviewBtn = [...document.querySelectorAll(".tab-btn")]
      .find((b) => b.textContent === "Overview")!;
    fireEvent.click(overviewBtn);
    expect(overviewBtn.classList.contains("active")).toBe(true);
  });
});
