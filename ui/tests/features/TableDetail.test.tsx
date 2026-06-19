// tests/features/TableDetail.test.tsx — Tests for TableDetail FaceToggle structure.

import { describe, it, expect } from "vitest";
import { fireEvent, render, waitFor } from "@solidjs/testing-library";
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

function renderTableDetail(
  detail: TableDetailData = baseDetail,
  tableFace: "source" | "analysis" = "source",
) {
  const { store } = createTestStore({
    tables: { ...initialTablesState, detail, tableFace },
  });
  return render(() => <TableDetail store={store} />);
}

function cardHeaders(): string[] {
  return [...document.querySelectorAll(".card-header h3")].map((h) => h.textContent ?? "");
}

function toggleBtns(): Element[] {
  return [...document.querySelectorAll(".face-toggle-btn")];
}

describe("TableDetail FaceToggle", () => {
  it("renders Source and Analysis toggle buttons", () => {
    renderTableDetail();
    const labels = toggleBtns().map((b) => b.textContent);
    expect(labels).toContain("Source");
    expect(labels).toContain("Analysis");
  });

  it("Source button is active by default", () => {
    renderTableDetail();
    const sourceBtn = toggleBtns().find((b) => b.textContent === "Source");
    expect(sourceBtn?.classList.contains("active")).toBe(true);
  });

  it("source face shows no-data message when columns_detail is empty", () => {
    renderTableDetail();
    expect(document.body.textContent).toContain("No column-level data available");
  });

  it("source face shows Columns card when columns_detail is populated", () => {
    const detail: TableDetailData = {
      ...baseDetail,
      columns_detail: [{ column: "orders.id", dw_readers: [], ps_readers: [], ps_writers: [], read_count: 1, write_count: 0 }],
    };
    renderTableDetail(detail);
    expect(cardHeaders().some((h) => h.startsWith("Columns"))).toBe(true);
  });

  it("analysis face shows DataWindow Readers card", () => {
    renderTableDetail(baseDetail, "analysis");
    expect(cardHeaders().some((h) => h.startsWith("DataWindow Readers"))).toBe(true);
    const names = [...document.querySelectorAll(".entity-card-name")].map((e) => e.textContent);
    expect(names).toContain("dw_orders");
  });

  it("analysis face shows Procedure Readers card with SELECT procedures", () => {
    renderTableDetail(baseDetail, "analysis");
    expect(cardHeaders().some((h) => h.startsWith("Procedure Readers"))).toBe(true);
    expect(document.body.textContent).toContain("get_orders");
  });

  it("analysis face shows Procedure Writers card with INSERT procedures", () => {
    renderTableDetail(baseDetail, "analysis");
    expect(cardHeaders().some((h) => h.startsWith("Procedure Writers"))).toBe(true);
    expect(document.body.textContent).toContain("add_order");
  });

  it("analysis face renders table analysis content", () => {
    renderTableDetail(baseDetail, "analysis");
    expect(document.querySelector(".card")).not.toBeNull();
  });

  it("clicking Analysis button activates analysis face", async () => {
    renderTableDetail();
    const analysisBtn = toggleBtns().find((b) => b.textContent === "Analysis")!;
    fireEvent.click(analysisBtn);
    await waitFor(() => expect(analysisBtn.classList.contains("active")).toBe(true));
  });
});
