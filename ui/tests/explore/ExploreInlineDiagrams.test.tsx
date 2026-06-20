// tests/explore/ExploreInlineDiagrams.test.tsx — Tests for inline diagrams in Explore.

import { describe, it, expect, vi, afterEach } from "vitest";
import { render, cleanup, fireEvent } from "@solidjs/testing-library";
import { createTestStore } from "../helpers.js";
import { TableDetailPanel } from "../../src/features/explore/Tables.js";
import { ProcDetailPanel } from "../../src/features/explore/ProcDetailPanel.js";
import { ExploreStoreContext } from "../../src/features/explore/ExploreContext.js";
import type { ExploreProcDetail } from "../../src/types/api.js";

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

const mockProcDetail: ExploreProcDetail = {
  proc_type: "function",
  params: "string as_sql",
  return_type: "integer",
  cyclomatic: 3,
  start_line: 10,
  end_line: 50,
  modifiers: null,
  source_rendered: "SELECT 1 FROM dual",
  ast: null,
  sql_statements: [{ line: 1, operation: "SELECT", raw_sql: "SELECT 1", formatted_sql: "SELECT 1", tables: ["dual"], columns: [], has_into: false, has_cursor: false, parse_ok: true }],
};

const mockProcDetailNoSql: ExploreProcDetail = {
  proc_type: "function",
  params: "",
  return_type: "void",
  cyclomatic: 1,
  start_line: 5,
  end_line: 10,
  modifiers: null,
  source_rendered: "Return 0",
  ast: null,
  sql_statements: [],
};

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

function renderProcDetail(nodeId: string, procCache?: Record<string, ExploreProcDetail | { error: string }>) {
  const { store } = createTestStore({
    explore: makeExploreState({
      selectedProc: nodeId,
      procCache: procCache ?? { [nodeId]: mockProcDetail },
    }),
  });
  return {
    ...render(() => (
      <ExploreStoreContext.Provider value={store}>
        <ProcDetailPanel nodeId={nodeId} />
      </ExploreStoreContext.Provider>
    )),
    store,
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

describe("Explore ProcDetailPanel — Diagram tab", () => {
  it("shows Diagram tab button for proc with SQL statements", () => {
    const { container } = renderProcDetail("lib:w_main:fn_query");
    const tabs = [...container.querySelectorAll(".explore-tab-btn")]
      .map((b) => b.textContent);
    expect(tabs).toContain("Diagram");
  });

  it("does not show Diagram tab button for proc without SQL", () => {
    const { container } = renderProcDetail("lib:w_main:fn_nosql", {
      "lib:w_main:fn_nosql": mockProcDetailNoSql,
    });
    const tabs = [...container.querySelectorAll(".explore-tab-btn")]
      .map((b) => b.textContent);
    expect(tabs).not.toContain("Diagram");
  });

  it("Diagram tab button is not active by default", () => {
    const { container } = renderProcDetail("lib:w_main:fn_query");
    const diagramBtn = [...container.querySelectorAll(".explore-tab-btn")]
      .find((b) => b.textContent === "Diagram");
    expect(diagramBtn?.classList.contains("active")).toBe(false);
  });

  it("clicking Diagram tab shows InlineDiagram with sql-lineage", async () => {
    vi.stubGlobal("fetch", () => new Promise(() => {}));
    const { container } = renderProcDetail("lib:w_main:fn_query");
    const diagramBtn = [...container.querySelectorAll(".explore-tab-btn")]
      .find((b) => b.textContent === "Diagram")!;
    fireEvent.click(diagramBtn);
    await vi.waitFor(() => {
      const btn = [...container.querySelectorAll(".explore-tab-btn")]
        .find((b) => b.textContent === "Diagram")!;
      expect(btn.classList.contains("active")).toBe(true);
    });
    expect(container.querySelector(".diagram-container")).not.toBeNull();
    vi.restoreAllMocks();
  });
});
