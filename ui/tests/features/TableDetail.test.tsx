// tests/features/TableDetail.test.tsx — Tests for TableDetail diagram tab.

import { describe, it, expect, vi } from "vitest";
import { fireEvent, render } from "@solidjs/testing-library";
import { TableDetail } from "../../src/features/tables/TableDetail.js";
import { createTestStore } from "../helpers.js";
import { initialTablesState } from "../../src/features/tables/types.js";
import type { TableDetail as TableDetailData } from "../../src/types/api.js";

const baseDetail: TableDetailData = {
  table_name: "orders",
  dw_count: 1,
  ps_count: 2,
  datawindows: [{ dw_name: "dw_orders", file: "a.srd" }],
  columns: [{ dw_name: "dw_orders", column_fqn: "orders.id", column_name: "id" }],
  columns_detail: [],
  where: [],
  procedures: [
    { object: "n_svc", proc_name: "get_orders", operation: "SELECT" },
    { object: "n_svc", proc_name: "add_order",  operation: "INSERT" },
  ],
  impact: { direct: [], inherited: [] },
};

function renderTableDetail(detail: TableDetailData = baseDetail) {
  const { store } = createTestStore({
    tables: { ...initialTablesState, detail },
  });
  return render(() => <TableDetail store={store} />);
}

describe("TableDetail diagram tab", () => {
  it("renders five tab buttons", () => {
    renderTableDetail();
    const tabs = [...document.querySelectorAll(".tab-btn")].map((b) => b.textContent);
    expect(tabs).toContain("Readers");
    expect(tabs).toContain("Writers");
    expect(tabs).toContain("Columns");
    expect(tabs).toContain("Impact");
    expect(tabs).toContain("Diagram");
    expect(tabs).toHaveLength(5);
  });

  it("defaults to Readers tab", () => {
    renderTableDetail();
    const activeTab = document.querySelector(".tab-btn.active");
    expect(activeTab?.textContent).toBe("Readers");
  });

  it("does not show 'Show proc-tables diagram' button in Impact tab", () => {
    renderTableDetail();
    const impactBtn = [...document.querySelectorAll(".tab-btn")]
      .find((b) => b.textContent === "Impact")!;
    fireEvent.click(impactBtn);
    expect(document.body.textContent).not.toContain("Show proc-tables diagram");
  });

  it("shows InlineDiagram containers in Diagram tab", async () => {
    vi.stubGlobal("fetch", () => new Promise(() => {}));
    renderTableDetail();
    const diagramBtn = [...document.querySelectorAll(".tab-btn")]
      .find((b) => b.textContent === "Diagram")!;
    fireEvent.click(diagramBtn);
    expect(diagramBtn.classList.contains("active")).toBe(true);
    expect(document.querySelectorAll(".diagram-container").length).toBeGreaterThanOrEqual(1);
    vi.restoreAllMocks();
  });

  it("switches between tabs correctly", async () => {
    renderTableDetail();
    const writersBtn = [...document.querySelectorAll(".tab-btn")]
      .find((b) => b.textContent === "Writers")!;
    fireEvent.click(writersBtn);
    expect(writersBtn.classList.contains("active")).toBe(true);

    const columnsBtn = [...document.querySelectorAll(".tab-btn")]
      .find((b) => b.textContent === "Columns")!;
    fireEvent.click(columnsBtn);
    expect(columnsBtn.classList.contains("active")).toBe(true);
  });
});
