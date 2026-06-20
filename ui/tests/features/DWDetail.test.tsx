// tests/features/DWDetail.test.tsx — Tests for source-first DWDetail.

import { describe, it, expect } from "vitest";
import { fireEvent, render } from "@solidjs/testing-library";
import { DWDetail } from "../../src/features/datawindows/DataWindows.js";
import { createTestStore } from "../helpers.js";
import { initialDatawindowsState } from "../../src/features/datawindows/reducer.js";
import type { DwDetailResponse } from "../../src/types/api.js";
import type { DataWindowFile } from "../../src/types/ast.generated.js";

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
    used_by_objects: ["w_main"],
    used_by_procs: [{ object: "n_svc", proc: "of_load" }],
    ...overrides,
  };
}

function renderDWDetail(overrides: Partial<DwDetailResponse> = {}) {
  const { store } = createTestStore({
    datawindows: { ...initialDatawindowsState, dwDetail: makeDw(overrides) },
  });
  render(() => <DWDetail store={store} />);
}

function summaryBar(): Element | null {
  return document.querySelector(".analysis-summary-bar");
}

function summaryPillBtn(label: string): Element | undefined {
  return [...(summaryBar()?.querySelectorAll("button") ?? [])].find((b) =>
    b.textContent?.includes(label),
  );
}

function cardHeaders(): string[] {
  return [...document.querySelectorAll(".card-header h3")].map((h) => h.textContent ?? "");
}

const MOCK_DW_FILE: DataWindowFile = {
  release: 19,
  object: { attrs: {} },
  table: null,
  bands: [
    { kind: { tag: "BkHeader" }, height: 64, color: null, autoSize: false, attrs: {} },
    { kind: { tag: "BkDetail" }, height: 80, color: null, autoSize: false, attrs: {} },
  ],
  groups: [],
  controls: [
    {
      type: "text",
      name: "t_label",
      band: { tag: "BkHeader" },
      id: 1,
      x: 10,
      y: 5,
      width: 200,
      height: 20,
      visible: true,
      expression: null,
      parsedExpression: null,
      format: null,
      parsedFormat: null,
      tabSeq: null,
      attrs: { text: "Customer Name" },
    },
    {
      type: "column",
      name: "col_id",
      band: { tag: "BkDetail" },
      id: 2,
      x: 10,
      y: 5,
      width: 100,
      height: 20,
      visible: true,
      expression: null,
      parsedExpression: null,
      format: null,
      parsedFormat: null,
      tabSeq: 1,
      attrs: {},
    },
  ],
  unknowns: [],
  meta: {},
};

describe("DWDetail preview", () => {
  function renderWithLayout() {
    const { store } = createTestStore({
      datawindows: {
        ...initialDatawindowsState,
        dwDetail: makeDw(),
        dwLayout: MOCK_DW_FILE,
      },
    });
    render(() => <DWDetail store={store} />);
    return document.querySelector(".dw-preview");
  }

  it("renders .dw-preview container", () => {
    expect(renderWithLayout()).not.toBeNull();
  });

  it("renders band labels for header and detail", () => {
    const preview = renderWithLayout();
    expect(preview?.textContent).toContain("header");
    expect(preview?.textContent).toContain("detail");
  });

  it("renders text control label", () => {
    const preview = renderWithLayout();
    expect(preview?.textContent).toContain("Customer Name");
  });

  it("renders column control with its name", () => {
    const preview = renderWithLayout();
    expect(preview?.textContent).toContain("col_id");
  });

  it("renders empty preview when dwLayout is null", () => {
    const { store } = createTestStore({
      datawindows: { ...initialDatawindowsState, dwDetail: makeDw(), dwLayout: null },
    });
    render(() => <DWDetail store={store} />);
    const preview = document.querySelector(".dw-preview");
    expect(preview).not.toBeNull();
    const wrapper = preview?.children[0] as HTMLElement | undefined;
    expect(wrapper?.children.length).toBe(0);
  });
});

describe("DWDetail source-first", () => {
  it("does not render a FaceToggle", () => {
    renderDWDetail();
    expect(document.querySelector(".face-toggle")).toBeNull();
  });

  it("renders AnalysisSummaryBar", () => {
    renderDWDetail();
    expect(summaryBar()).not.toBeNull();
  });

  it("controls table visible without toggling", () => {
    renderDWDetail();
    expect(cardHeaders().some((h) => h.startsWith("Controls"))).toBe(true);
  });

  it("controls hidden when no controls", () => {
    renderDWDetail({ controls: [] });
    expect(cardHeaders().some((h) => h.startsWith("Controls"))).toBe(false);
  });

  it("source code card visible without toggling", () => {
    renderDWDetail();
    expect(cardHeaders()).toContain("Source");
  });

  it("Tables pill shows count from retrieve_tables", () => {
    renderDWDetail({ retrieve_tables: ["orders", "customers"] });
    expect(summaryBar()?.textContent).toContain("Tables (2)");
  });

  it("Tables pill hidden when retrieve_tables empty", () => {
    renderDWDetail({ retrieve_tables: [] });
    expect(summaryBar()?.textContent).not.toContain("Tables");
  });

  it("clicking Tables pill opens panel with table names", () => {
    renderDWDetail({ retrieve_tables: ["orders", "customers"] });
    fireEvent.click(summaryPillBtn("Tables")!);
    expect(document.body.textContent).toContain("orders");
    expect(document.body.textContent).toContain("customers");
  });

  it("Used By Objects pill shown when used_by_objects non-empty", () => {
    renderDWDetail({ used_by_objects: ["w_main"] });
    expect(summaryBar()?.textContent).toContain("Used By Objects (1)");
  });

  it("Used By Objects pill hidden when empty", () => {
    renderDWDetail({ used_by_objects: [] });
    expect(summaryBar()?.textContent).not.toContain("Used By Objects");
  });

  it("clicking Used By Objects pill opens panel with object name", () => {
    renderDWDetail({ used_by_objects: ["w_main"] });
    fireEvent.click(summaryPillBtn("Used By Objects")!);
    expect(document.body.textContent).toContain("w_main");
  });

  it("Used By Procs pill shown when used_by_procs non-empty", () => {
    renderDWDetail({ used_by_procs: [{ object: "n_svc", proc: "of_load" }] });
    expect(summaryBar()?.textContent).toContain("Used By Procs (1)");
  });

  it("Used By Procs pill hidden when empty", () => {
    renderDWDetail({ used_by_procs: [] });
    expect(summaryBar()?.textContent).not.toContain("Used By Procs");
  });

  it("Retrieve pill shown when args present", () => {
    renderDWDetail({ arguments: [{ arg_name: "arg_id", arg_type: "long" }], retrieve_where: [] });
    expect(summaryBar()?.textContent).toContain("Retrieve");
  });

  it("Retrieve pill shown when where clauses present", () => {
    renderDWDetail({ arguments: [], retrieve_where: [{ idx: 1, exp1: "orders.id", op: "=", exp2: ":arg_id", logic: "" }] });
    expect(summaryBar()?.textContent).toContain("Retrieve");
  });

  it("Retrieve pill hidden when no args and no where", () => {
    renderDWDetail({ arguments: [], retrieve_where: [] });
    expect(summaryBar()?.textContent).not.toContain("Retrieve");
  });

  it("clicking Retrieve pill opens Retrieve Definition panel", () => {
    renderDWDetail({ arguments: [{ arg_name: "arg_id", arg_type: "long" }] });
    fireEvent.click(summaryPillBtn("Retrieve")!);
    expect(document.body.textContent).toContain("Retrieve Definition");
    expect(document.body.textContent).toContain("arg_id");
  });
});
