// tests/features/TableDetail.test.tsx — Tests for source-first TableDetail.

import { describe, it, expect } from "vitest";
import { fireEvent, render } from "@solidjs/testing-library";
import { TableDetail } from "../../app/src/views/features/tables/TableDetail.js";
import { createTestStore } from "../helpers.js";
import { initialTablesState } from "@pb/platform";
import type { TableDetail as TableDetailData } from "@pb/platform";

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
  render(() => <TableDetail store={store} />);
}

function summaryBar(): Element | null {
  return document.querySelector(".analysis-summary-bar");
}

function summaryPillBtn(label: string): Element | undefined {
  return [...(summaryBar()?.querySelectorAll("button") ?? [])].find((b) =>
    b.textContent?.startsWith(label),
  );
}

function cardHeaders(): string[] {
  return [...document.querySelectorAll(".card-header h3")].map((h) => h.textContent ?? "");
}

describe("TableDetail source-first", () => {
  it("does not render a FaceToggle", () => {
    renderTableDetail();
    expect(document.querySelector(".face-toggle")).toBeNull();
  });

  it("renders AnalysisSummaryBar", () => {
    renderTableDetail();
    expect(summaryBar()).not.toBeNull();
  });

  it("columns always visible without toggling", () => {
    const detail: TableDetailData = {
      ...baseDetail,
      columns_detail: [{ column: "orders.id", dw_readers: [], ps_readers: [], ps_writers: [], read_count: 1, write_count: 0 }],
    };
    renderTableDetail(detail);
    expect(cardHeaders().some((h) => h.startsWith("Columns"))).toBe(true);
  });

  it("no-data message shown when columns_detail empty", () => {
    renderTableDetail({ ...baseDetail, columns_detail: [] });
    expect(document.body.textContent).toContain("No column-level data available");
  });

  it("DW Readers pill shows count", () => {
    renderTableDetail();
    expect(summaryBar()?.textContent).toContain("DW Readers (1)");
  });

  it("clicking DW Readers pill opens panel with dw name", () => {
    renderTableDetail();
    fireEvent.click(summaryPillBtn("DW Readers")!);
    expect(document.body.textContent).toContain("dw_orders");
  });

  it("Readers pill shows SELECT count", () => {
    renderTableDetail();
    expect(summaryBar()?.textContent).toContain("Readers (1)");
  });

  it("clicking Readers pill opens panel with SELECT procedure", () => {
    renderTableDetail();
    fireEvent.click(summaryPillBtn("Readers")!);
    expect(document.body.textContent).toContain("get_orders");
  });

  it("Writers pill shows INSERT/UPDATE/DELETE count", () => {
    renderTableDetail();
    expect(summaryBar()?.textContent).toContain("Writers (1)");
  });

  it("clicking Writers pill opens panel with INSERT procedure", () => {
    renderTableDetail();
    fireEvent.click(summaryPillBtn("Writers")!);
    expect(document.body.textContent).toContain("add_order");
  });

  it("Impact pill hidden when impact is empty", () => {
    renderTableDetail({ ...baseDetail, impact: { direct: [], inherited: [] } });
    expect(summaryBar()?.textContent).not.toContain("Impact");
  });

  it("Impact pill shown when direct impact non-empty", () => {
    const detail: TableDetailData = {
      ...baseDetail,
      impact: {
        direct: [{ object: "n_svc", source: "powerscript", operation: "SELECT" }],
        inherited: [],
      },
    };
    renderTableDetail(detail);
    expect(summaryBar()?.textContent).toContain("Impact (1)");
  });
});
