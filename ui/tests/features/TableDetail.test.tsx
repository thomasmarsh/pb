// tests/features/TableDetail.test.tsx — Tests for source-first TableDetail.

import { describe, it, expect } from "vitest";
import { fireEvent, render } from "@solidjs/testing-library";
import { TableDetail } from "../../app/src/views/features/tables/TableDetail.js";
import { createTestStore } from "../helpers.js";
import { initialTablesState } from "@pb/platform";
import type { TableDetail as TableDetailData, ColumnUsageResponse, CoUpdateRitualsResponse, DecompositionCandidatesResponse, ColumnAffinityResponse } from "@pb/platform";

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
  columnAffinity: ColumnAffinityResponse | null = null,
) {
  const { store } = createTestStore({
    tables: { ...initialTablesState, detail, columnUsage, coUpdateRituals, decompositionCandidates, columnAffinity },
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

    it("excludes dead/write-only columns from a same-named table in a different namespace", () => {
      const detail: TableDetailData = { ...baseDetail, namespace: "clims" };
      const usage: ColumnUsageResponse = {
        dead: [{ namespace: "clims_archive", table: "orders", column: "legacy_flag" }],
        write_only: [{ namespace: "clims_archive", table: "orders", column: "audit_stamp" }],
        read_only: [],
        read_write: [],
      };
      renderTableDetail(detail, usage);
      expect(summaryBar()?.textContent).not.toContain("Column Usage");
    });

    it("includes dead/write-only columns when namespace matches the table's own namespace", () => {
      const detail: TableDetailData = { ...baseDetail, namespace: "clims" };
      const usage: ColumnUsageResponse = {
        dead: [{ namespace: "clims", table: "orders", column: "legacy_flag" }],
        write_only: [{ namespace: "clims", table: "orders", column: "audit_stamp" }],
        read_only: [],
        read_write: [],
      };
      renderTableDetail(detail, usage);
      expect(summaryBar()?.textContent).toContain("Column Usage (2)");
    });

    it("treats null and undefined namespace as equal for the common single-schema corpus", () => {
      const usage: ColumnUsageResponse = {
        dead: [{ namespace: null, table: "orders", column: "legacy_flag" }],
        write_only: [],
        read_only: [],
        read_write: [],
      };
      renderTableDetail(baseDetail, usage);
      expect(summaryBar()?.textContent).toContain("Column Usage (1)");
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

    it("excludes rituals whose column belongs to a same-named table in a different namespace", () => {
      const detail: TableDetailData = { ...baseDetail, namespace: "clims" };
      const rituals: CoUpdateRitualsResponse = {
        rituals: [{
          column_a: { namespace: "clims_archive", table: "orders", column: "status" },
          column_b: { namespace: "clims_archive", table: "orders", column: "status_reason" },
          co_write_support: 3,
          violations: [],
        }],
      };
      renderTableDetail(detail, null, rituals);
      expect(summaryBar()?.textContent).not.toContain("Co-update Rituals");
    });

    it("includes rituals when the ritual column's namespace matches the table's own namespace", () => {
      const detail: TableDetailData = { ...baseDetail, namespace: "clims" };
      const rituals: CoUpdateRitualsResponse = {
        rituals: [{
          column_a: { namespace: "clims", table: "orders", column: "status" },
          column_b: { namespace: "clims", table: "orders", column: "status_reason" },
          co_write_support: 3,
          violations: [],
        }],
      };
      renderTableDetail(detail, null, rituals);
      expect(summaryBar()?.textContent).toContain("Co-update Rituals (1)");
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
      const paths = Array.from({ length: 17 }, (_, i) => ({
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
          coslice_size: 17,
          score: 0,
          paths,
        }],
      };
      renderTableDetail(baseDetail, null, null, data);
      fireEvent.click(summaryPillBtn("Decomposition")!);
      expect(document.body.textContent).toContain("proc_0");
      expect(document.body.textContent).toContain("proc_14");
      expect(document.body.textContent).not.toContain("proc_15");
      expect(document.body.textContent).toContain("Show 2 more");

      fireEvent.click([...document.querySelectorAll("button")].find((b) => b.textContent === "Show 2 more")!);
      expect(document.body.textContent).toContain("proc_15");
      expect(document.body.textContent).toContain("proc_16");
      expect(document.body.textContent).toContain("Show less");
    });

    it("clicking the panel's info button opens the explainer with worked example content", () => {
      renderTableDetail();
      fireEvent.click(summaryPillBtn("Decomposition")!);
      fireEvent.click(document.querySelector("[aria-label='What is this?']")!);
      expect(document.body.textContent).toContain("blast radius");
      expect(document.body.textContent).toContain("employee(name, email, salary, hire_date, dept_id)");
      expect(document.body.textContent).toContain("employee_profile");
    });

    it("Escape closes the explainer along with the other panels", () => {
      renderTableDetail();
      fireEvent.click(summaryPillBtn("Decomposition")!);
      fireEvent.click(document.querySelector("[aria-label='What is this?']")!);
      expect(document.body.textContent).toContain("employee_profile");
      fireEvent.keyDown(document.querySelector(".detail-body")!.parentElement!, { key: "Escape" });
      expect(document.body.textContent).not.toContain("employee_profile");
    });

    describe("columns-view layout (Finder-style master/detail)", () => {
      function twoCandidateData(): DecompositionCandidatesResponse {
        return {
          table: "orders",
          namespace: null,
          candidates: [
            {
              columns: ["a", "b"],
              similarity: 0.9,
              ritual_support: 2,
              unenforced_fk_count: 0,
              coslice_size: 3,
              score: 0.8,
              paths: [{
                target: { kind: "sql", file: "/tmp/x.srw", object: "n_svc", proc_name: "proc_top", line: 1 },
                direction: "backward",
                legs: [{
                  from_object: { kind: "column", namespace: null, table: "orders", column: "a" },
                  to_object: { kind: "sql", file: "/tmp/x.srw", object: "n_svc", proc_name: "proc_top", line: 1 },
                  leg_kind: "writes",
                }],
              }],
            },
            {
              columns: ["c", "d"],
              similarity: 0.5,
              ritual_support: 1,
              unenforced_fk_count: 0,
              coslice_size: 1,
              score: 0.2,
              paths: [{
                target: { kind: "sql", file: "/tmp/y.srw", object: "n_svc", proc_name: "proc_second", line: 2 },
                direction: "backward",
                legs: [{
                  from_object: { kind: "column", namespace: null, table: "orders", column: "c" },
                  to_object: { kind: "sql", file: "/tmp/y.srw", object: "n_svc", proc_name: "proc_second", line: 2 },
                  leg_kind: "writes",
                }],
              }],
            },
          ],
        };
      }

      function decompRow(colText: string): Element | undefined {
        return [...document.querySelectorAll(".decomp-master tbody tr")].find((r) =>
          r.textContent?.includes(colText),
        );
      }

      it("renders a master pane with only scoring columns and a separate detail pane", () => {
        renderTableDetail(baseDetail, null, null, twoCandidateData());
        fireEvent.click(summaryPillBtn("Decomposition")!);

        expect(document.querySelector(".decomp-master")).not.toBeNull();
        expect(document.querySelector(".decomp-detail")).not.toBeNull();
        // Master pane header has no "Evidence paths" column.
        const masterHeaders = [...document.querySelectorAll(".decomp-master thead th")].map((h) => h.textContent);
        expect(masterHeaders).not.toContain("Evidence paths");
        expect(document.body.textContent).toContain("a, b");
        expect(document.body.textContent).toContain("c, d");
      });

      it("previews the top-scored candidate's evidence in the detail pane by default", () => {
        renderTableDetail(baseDetail, null, null, twoCandidateData());
        fireEvent.click(summaryPillBtn("Decomposition")!);

        const detail = document.querySelector(".decomp-detail");
        expect(detail?.textContent).toContain("proc_top");
        expect(detail?.textContent).not.toContain("proc_second");
      });

      it("clicking a master row pins its evidence in the detail pane", () => {
        renderTableDetail(baseDetail, null, null, twoCandidateData());
        fireEvent.click(summaryPillBtn("Decomposition")!);

        fireEvent.click(decompRow("c, d")!);
        const detail = document.querySelector(".decomp-detail");
        expect(detail?.textContent).toContain("proc_second");
        expect(detail?.textContent).not.toContain("proc_top");
      });

      it("hovering a different row previews it without losing the pinned selection", () => {
        renderTableDetail(baseDetail, null, null, twoCandidateData());
        fireEvent.click(summaryPillBtn("Decomposition")!);
        fireEvent.click(decompRow("c, d")!);

        fireEvent.mouseEnter(decompRow("a, b")!);
        expect(document.querySelector(".decomp-detail")?.textContent).toContain("proc_top");

        fireEvent.mouseLeave(document.querySelector(".decomp-columns-view")!);
        expect(document.querySelector(".decomp-detail")?.textContent).toContain("proc_second");
      });

      it("keeps the hover preview while the mouse travels into the detail pane", () => {
        renderTableDetail(baseDetail, null, null, twoCandidateData());
        fireEvent.click(summaryPillBtn("Decomposition")!);
        fireEvent.click(decompRow("c, d")!);

        fireEvent.mouseEnter(decompRow("a, b")!);
        // Leaving the row itself (e.g. moving toward the detail pane) must not
        // revert the preview — only leaving the whole master+detail widget does.
        fireEvent.mouseLeave(decompRow("a, b")!);
        expect(document.querySelector(".decomp-detail")?.textContent).toContain("proc_top");

        fireEvent.mouseEnter(document.querySelector(".decomp-detail")!);
        expect(document.querySelector(".decomp-detail")?.textContent).toContain("proc_top");
      });
    });
  });

  describe("Column Affinity pill (Plan 153 D3)", () => {
    it("always shown, no count", () => {
      renderTableDetail();
      expect(summaryBar()?.textContent).toContain("Column Affinity");
    });

    it("clicking the pill opens a panel titled 'Column Affinity Heat Matrix'", () => {
      renderTableDetail();
      fireEvent.click(summaryPillBtn("Column Affinity")!);
      expect(document.body.textContent).toContain("Column Affinity Heat Matrix");
    });

    it("clicking the pill again closes the panel", () => {
      renderTableDetail();
      fireEvent.click(summaryPillBtn("Column Affinity")!);
      expect(document.body.textContent).toContain("Column Affinity Heat Matrix");
      fireEvent.click(summaryPillBtn("Column Affinity")!);
      expect(document.body.textContent).not.toContain("Column Affinity Heat Matrix");
    });

    it("renders the heat matrix cells and dendrogram merges", () => {
      const data: ColumnAffinityResponse = {
        table: "orders",
        namespace: null,
        columns: ["name", "surname"],
        co_access_matrix: [[27, 27], [27, 27]],
        dendrogram: [{ similarity: 1.0, members: ["name", "surname"] }],
      };
      renderTableDetail(baseDetail, null, null, null, data);
      fireEvent.click(summaryPillBtn("Column Affinity")!);
      expect(document.body.textContent).toContain("name");
      expect(document.body.textContent).toContain("surname");
      expect(document.body.textContent).toContain("27");
      expect(document.body.textContent).toContain("similarity 1.000");
    });

    it("shows a fallback message when the table has no touched columns", () => {
      const data: ColumnAffinityResponse = { table: "orders", namespace: null, columns: [], co_access_matrix: [], dendrogram: [] };
      renderTableDetail(baseDetail, null, null, null, data);
      fireEvent.click(summaryPillBtn("Column Affinity")!);
      expect(document.body.textContent).toContain("No column affinity data for this table.");
    });

    it("clicking the panel's info button opens the explainer with worked example content", () => {
      renderTableDetail();
      fireEvent.click(summaryPillBtn("Column Affinity")!);
      fireEvent.click(document.querySelector("[aria-label='What is this?']")!);
      expect(document.body.textContent).toContain("average-linkage clustering");
      expect(document.body.textContent).toContain("employee(name, email, salary, hire_date, dept_id)");
    });

    it("Escape closes the explainer along with the other panels", () => {
      renderTableDetail();
      fireEvent.click(summaryPillBtn("Column Affinity")!);
      fireEvent.click(document.querySelector("[aria-label='What is this?']")!);
      expect(document.body.textContent).toContain("average-linkage clustering");
      fireEvent.keyDown(document.querySelector(".detail-body")!.parentElement!, { key: "Escape" });
      expect(document.body.textContent).not.toContain("average-linkage clustering");
    });
  });
});
