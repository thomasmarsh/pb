// tests/explore/ExploreInlineDiagrams.test.tsx — Tests for inline diagrams in Explore.

import { describe, it, expect, vi, afterEach } from "vitest";
import { render, cleanup } from "@solidjs/testing-library";
import { createTestStore } from "../helpers.js";
import { TableDetailPanel } from "../../app/src/views/features/explore/Tables.js";
import { DwDetailPanel } from "../../app/src/views/features/explore/DwDetailPanel.js";
import { ExploreStoreContext } from "../../app/src/views/features/explore/ExploreContext.js";
import type { ExploreProcDetail, DwDetailResponse } from "@pb/platform";
import type { DataWindowFile } from "@pb/interpreter";

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

const sampleLibraries = [
  {
    name: "app.pbl",
    objects: [
      {
        name: "w_main", kind: "powerscript", file: "app.pbl",
        procedures: [
          { name: "fn_query", proc_type: "function", params: "", return_type: "", cyclomatic: 5, start_line: 10, end_line: 50, object: "w_main", modifiers: null },
          { name: "fn_nosql", proc_type: "function", params: "", return_type: "", cyclomatic: 1, start_line: 20, end_line: 30, object: "w_main", modifiers: null },
        ],
      },
    ],
  },
];

function makeExploreState(overrides?: Partial<Record<string, unknown>>) {
  return {
    libraries: sampleLibraries,
    expandedNodes: new Set<string>(),
    selectedProc: null,
    selectedObject: null,
    highlightedProcName: null,
    selectedDw: null,
    procCache: {} as Record<string, ExploreProcDetail | { error: string }>,
    dwCache: {},
    dwLayoutCache: {},
    objectSourceCache: {},
    loading: false,
    activeTab: "source" as const,
    treeFilter: "",
    highlightedLine: null,
    sidebarGroups: { sourceTree: true, entityNav: false, analysisNav: false },
    sidebarCollapsed: false,
    helpOverlayOpen: false,
    tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
    ...overrides,
  };
}

describe("Explore Tables — InlineDiagram", () => {
  it("does not show Show in diagram button", () => {
    vi.stubGlobal("fetch", () => new Promise(() => {}));
    const { store } = createTestStore({
      explore: makeExploreState({
        tables: {
          items: [{ table_name: "orders", dw_count: 1, file_count: 1 }],
          filter: "",
          selected: "orders",
          detail: {
            table_name: "orders",
            dw_count: 1,
            datawindows: [{ dw_name: "dw_orders", file: "a.srd" }],
            columns: [],
            where: [],
          },
          loading: false,
          detailLoading: false,
        },
      }),
    });
    const { container } = render(() => <TableDetailPanel store={store} />);
    expect(container.textContent).not.toContain("Show in diagram");
    vi.restoreAllMocks();
  });

  it("renders dw-tables InlineDiagram in table detail", async () => {
    vi.stubGlobal("fetch", () => new Promise(() => {}));
    const { store } = createTestStore({
      explore: makeExploreState({
        tables: {
          items: [{ table_name: "orders", dw_count: 1, file_count: 1 }],
          filter: "",
          selected: "orders",
          detail: {
            table_name: "orders",
            dw_count: 1,
            datawindows: [{ dw_name: "dw_orders", file: "a.srd" }],
            columns: [],
            where: [],
          },
          loading: false,
          detailLoading: false,
        },
      }),
    });
    const { container } = render(() => <TableDetailPanel store={store} />);
    await vi.waitUntil(() => container.querySelector(".diagram-container") != null);
    expect(container.querySelector(".diagram-container")).not.toBeNull();
    vi.restoreAllMocks();
  });
});

const MOCK_DW_DETAIL: DwDetailResponse = {
  name: "dw_orders",
  file: "app.pbl",
  controls: [],
  retrieve_tables: [],
  retrieve_columns: [],
  retrieve_where: [],
  arguments: [],
  source: "select 1 from orders",
  used_by_objects: [],
  used_by_procs: [],
};

const MOCK_DW_LAYOUT: DataWindowFile = {
  release: 19,
  object: { attrs: {} },
  table: null,
  bands: [
    { kind: { tag: "BkHeader" }, height: 48, color: null, autoSize: false, attrs: {} },
    { kind: { tag: "BkDetail" }, height: 64, color: null, autoSize: false, attrs: {} },
  ],
  groups: [],
  controls: [
    {
      type: "text", name: "lbl_id", band: { tag: "BkHeader" },
      id: 1, x: 10, y: 4, width: 120, height: 18,
      visible: true, expression: null, parsedExpression: null,
      format: null, parsedFormat: null, tabSeq: null,
      attrs: { text: "Order ID" },
    },
  ],
  unknowns: [],
  meta: {},
};

describe("DwDetailPanel — preview from dwLayoutCache", () => {
  const NODE_ID = "dw::dw_orders";

  function renderDwPanel(layout: DataWindowFile | null) {
    const { store } = createTestStore({
      explore: makeExploreState({
        selectedDw: NODE_ID,
        dwCache: { [NODE_ID]: MOCK_DW_DETAIL },
        dwLayoutCache: layout ? { [NODE_ID]: layout } : {},
      }),
    });
    render(() => (
      <ExploreStoreContext.Provider value={store}>
        <DwDetailPanel nodeId={NODE_ID} />
      </ExploreStoreContext.Provider>
    ));
    return document.querySelector(".dw-preview");
  }

  it("renders .dw-preview when dwLayoutCache is populated", () => {
    expect(renderDwPanel(MOCK_DW_LAYOUT)).not.toBeNull();
  });

  it("renders band labels from layout", () => {
    const preview = renderDwPanel(MOCK_DW_LAYOUT);
    expect(preview?.textContent).toContain("header");
    expect(preview?.textContent).toContain("detail");
  });

  it("renders text control label from layout", () => {
    const preview = renderDwPanel(MOCK_DW_LAYOUT);
    expect(preview?.textContent).toContain("Order ID");
  });

  it("renders empty preview when no layout in cache", () => {
    const preview = renderDwPanel(null);
    expect(preview).not.toBeNull();
    const wrapper = preview?.children[0] as HTMLElement | undefined;
    expect(wrapper?.children.length).toBe(0);
  });
});
