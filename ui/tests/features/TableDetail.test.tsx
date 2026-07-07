// tests/features/TableDetail.test.tsx — Tests for source-first TableDetail.

import { describe, it, expect } from "vitest";
import { fireEvent, render } from "@solidjs/testing-library";
import { TableDetail } from "../../app/src/views/features/tables/TableDetail.js";
import { createTestStore } from "../helpers.js";
import { initialTablesState } from "@pb/platform";
import type { TableDetail as TableDetailData, ColumnUsageResponse, CoUpdateRitualsResponse, DecompositionCandidatesResponse } from "@pb/platform";

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
  columnUsage: ColumnUsageResponse | null = null,
  coUpdateRituals: CoUpdateRitualsResponse | null = null,
  decompositionCandidates: DecompositionCandidatesResponse | null = null,
) {
  const { store } = createTestStore({
    tables: { ...initialTablesState, detail, columnUsage, coUpdateRituals, decompositionCandidates },
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

  describe("Column Usage pill (Plan 153 D4)", () => {
    it("hidden when columnUsage is not loaded", () => {
      renderTableDetail(baseDetail, null);
      expect(summaryBar()?.textContent).not.toContain("Column Usage");
    });

    it("hidden when this table has no dead/write-only columns", () => {
      const usage: ColumnUsageResponse = {
        dead: [{ namespace: null, table: "other_table", column: "x" }],
        write_only: [],
        read_only: [],
        read_write: [],
      };
      renderTableDetail(baseDetail, usage);
      expect(summaryBar()?.textContent).not.toContain("Column Usage");
    });

    it("shows count of this table's dead + write-only columns", () => {
      const usage: ColumnUsageResponse = {
        dead: [{ namespace: null, table: "orders", column: "legacy_flag" }],
        write_only: [{ namespace: null, table: "orders", column: "audit_stamp" }],
        read_only: [],
        read_write: [],
      };
      renderTableDetail(baseDetail, usage);
      expect(summaryBar()?.textContent).toContain("Column Usage (2)");
    });

    it("clicking the pill opens a panel listing dead and write-only columns", () => {
      const usage: ColumnUsageResponse = {
        dead: [{ namespace: null, table: "orders", column: "legacy_flag" }],
        write_only: [{ namespace: null, table: "orders", column: "audit_stamp" }],
        read_only: [],
        read_write: [],
      };
      renderTableDetail(baseDetail, usage);
      fireEvent.click(summaryPillBtn("Column Usage")!);
      expect(document.body.textContent).toContain("legacy_flag");
      expect(document.body.textContent).toContain("audit_stamp");
    });
  });

  describe("Co-update Rituals pill (Plan 153 D1)", () => {
    it("hidden when coUpdateRituals is not loaded", () => {
      renderTableDetail(baseDetail, null, null);
      expect(summaryBar()?.textContent).not.toContain("Co-update Rituals");
    });

    it("hidden when this table has no rituals", () => {
      const rituals: CoUpdateRitualsResponse = {
        rituals: [{
          column_a: { namespace: null, table: "other_table", column: "x" },
          column_b: { namespace: null, table: "other_table", column: "y" },
          co_write_support: 3,
          violations: [],
        }],
      };
      renderTableDetail(baseDetail, null, rituals);
      expect(summaryBar()?.textContent).not.toContain("Co-update Rituals");
    });

    it("shows count of this table's rituals", () => {
      const rituals: CoUpdateRitualsResponse = {
        rituals: [{
          column_a: { namespace: null, table: "orders", column: "status" },
          column_b: { namespace: null, table: "orders", column: "status_reason" },
          co_write_support: 3,
          violations: [],
        }],
      };
      renderTableDetail(baseDetail, null, rituals);
      expect(summaryBar()?.textContent).toContain("Co-update Rituals (1)");
    });

    it("clicking the pill opens a panel listing the ritual columns and violations", () => {
      const rituals: CoUpdateRitualsResponse = {
        rituals: [{
          column_a: { namespace: null, table: "orders", column: "status" },
          column_b: { namespace: null, table: "orders", column: "status_reason" },
          co_write_support: 3,
          violations: [
            { file: "n_svc.srw", object: "n_svc", proc_name: "set_status", line: 42, written_column: { namespace: null, table: "orders", column: "status" } },
          ],
        }],
      };
      renderTableDetail(baseDetail, null, rituals);
      fireEvent.click(summaryPillBtn("Co-update Rituals")!);
      expect(document.body.textContent).toContain("orders.status");
      expect(document.body.textContent).toContain("orders.status_reason");
      expect(document.body.textContent).toContain("set_status");
    });
  });

  describe("Decomposition Candidates pill (Plan 153 D5)", () => {
    it("always shown, no count", () => {
      renderTableDetail();
      expect(summaryBar()?.textContent).toContain("Decomposition");
    });

    it("clicking the pill opens a panel titled 'Decomposition Candidates'", () => {
      renderTableDetail();
      fireEvent.click(summaryPillBtn("Decomposition")!);
      expect(document.body.textContent).toContain("Decomposition Candidates");
    });

    it("clicking the pill again closes the panel", () => {
      renderTableDetail();
      fireEvent.click(summaryPillBtn("Decomposition")!);
      expect(document.body.textContent).toContain("Decomposition Candidates");
      fireEvent.click(summaryPillBtn("Decomposition")!);
      expect(document.body.textContent).not.toContain("Decomposition Candidates");
    });

    it("renders a row per candidate with structured, clickable evidence path entities", () => {
      const data: DecompositionCandidatesResponse = {
        table: "orders",
        namespace: null,
        candidates: [{
          columns: ["status", "status_reason"],
          similarity: 1.0,
          ritual_support: 3,
          unenforced_fk_count: 0,
          coslice_size: 2,
          score: 1.5,
          paths: [
            {
              target: { kind: "sql", file: "/tmp/pb-extract-abc/n_svc.srw", object: "n_svc", proc_name: "set_status", line: 42 },
              direction: "backward",
              legs: [{
                from_object: { kind: "column", namespace: null, table: "orders", column: "status" },
                to_object: { kind: "sql", file: "/tmp/pb-extract-abc/n_svc.srw", object: "n_svc", proc_name: "set_status", line: 42 },
                leg_kind: "writes",
              }],
            },
            {
              target: { kind: "dw_retrieve", file: "/tmp/pb-extract-abc/dw_orders.srd", dw_name: "dw_orders" },
              direction: "backward",
              legs: [{
                from_object: { kind: "column", namespace: null, table: "orders", column: "status" },
                to_object: { kind: "dw_retrieve", file: "/tmp/pb-extract-abc/dw_orders.srd", dw_name: "dw_orders" },
                leg_kind: "retrieve",
              }],
            },
          ],
        }],
      };
      renderTableDetail(baseDetail, null, null, data);
      fireEvent.click(summaryPillBtn("Decomposition")!);
      expect(document.body.textContent).toContain("status, status_reason");
      expect(document.body.textContent).toContain("n_svc.set_status");
      expect(document.body.textContent).toContain("line 42");
      expect(document.body.textContent).toContain("dw_orders");
      expect(document.body.textContent).not.toContain("/pb-extract-");
    });

    it("truncates evidence paths beyond the preview count with a 'Show N more' toggle", () => {
      const paths = Array.from({ length: 7 }, (_, i) => ({
        target: { kind: "sql" as const, file: "/tmp/x.srw", object: "n_svc", proc_name: `proc_${i}`, line: i },
        direction: "backward",
        legs: [{
          from_object: { kind: "column" as const, namespace: null, table: "orders", column: "status" },
          to_object: { kind: "sql" as const, file: "/tmp/x.srw", object: "n_svc", proc_name: `proc_${i}`, line: i },
          leg_kind: "writes",
        }],
      }));
      const data: DecompositionCandidatesResponse = {
        table: "orders",
        namespace: null,
        candidates: [{
          columns: ["status"],
          similarity: 1.0,
          ritual_support: 0,
          unenforced_fk_count: 0,
          coslice_size: 7,
          score: 0,
          paths,
        }],
      };
      renderTableDetail(baseDetail, null, null, data);
      fireEvent.click(summaryPillBtn("Decomposition")!);
      expect(document.body.textContent).toContain("proc_0");
      expect(document.body.textContent).toContain("proc_4");
      expect(document.body.textContent).not.toContain("proc_5");
      expect(document.body.textContent).toContain("Show 2 more");

      fireEvent.click([...document.querySelectorAll("button")].find((b) => b.textContent === "Show 2 more")!);
      expect(document.body.textContent).toContain("proc_5");
      expect(document.body.textContent).toContain("proc_6");
      expect(document.body.textContent).toContain("Show less");
    });
  });
});
