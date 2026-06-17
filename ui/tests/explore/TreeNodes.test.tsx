// tests/explore/TreeNodes.test.tsx — Tests for extracted tree node components.

import { describe, it, expect } from "vitest";
import { screen, fireEvent } from "@solidjs/testing-library";
import { render } from "@solidjs/testing-library";
import { ExploreStoreContext } from "../../src/features/explore/ExploreContext.js";
import { createTestStore } from "../helpers.js";
import { ProcNode, ObjectNode, LibraryNode } from "../../src/features/explore/TreeNodes.js";

function renderWithExplore(overrides?: Record<string, unknown>) {
  const { store, captured } = createTestStore({
    explore: {
      libraries: [],
      expandedNodes: new Set<string>(),
      selectedProc: null,
      selectedDw: null,
      procCache: {},
      dwCache: {},
      loading: false,
      activeTab: "source",
      treeFilter: "",
      highlightedLine: null,
      leftTab: "objects",
      tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
      ...overrides,
    },
  });
  const result = render(() => (
    <ExploreStoreContext.Provider value={store}>
      <div />
    </ExploreStoreContext.Provider>
  ));
  return { ...result, captured, store };
}

describe("ProcNode", () => {
  it("renders procedure name", () => {
    const { store } = createTestStore({
      explore: {
        libraries: [], expandedNodes: new Set(), selectedProc: null, selectedDw: null,
        procCache: {}, dwCache: {}, loading: false, activeTab: "source", treeFilter: "",
        highlightedLine: null, leftTab: "objects",
        tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
      },
    });
    render(() => (
      <ExploreStoreContext.Provider value={store}>
        <ProcNode objName="w_main" proc={{ name: "of_init", proc_type: "function", params: "(n)", return_type: "void", cyclomatic: 3, start_line: 10, end_line: 20 }} depth={1} />
      </ExploreStoreContext.Provider>
    ));
    expect(screen.getByText("of_init")).toBeDefined();
  });

  it("shows proc_type badge", () => {
    const { store } = createTestStore({
      explore: {
        libraries: [], expandedNodes: new Set(), selectedProc: null, selectedDw: null,
        procCache: {}, dwCache: {}, loading: false, activeTab: "source", treeFilter: "",
        highlightedLine: null, leftTab: "objects",
        tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
      },
    });
    render(() => (
      <ExploreStoreContext.Provider value={store}>
        <ProcNode objName="w_main" proc={{ name: "of_init", proc_type: "function", params: "", return_type: "", cyclomatic: null, start_line: null, end_line: null }} depth={1} />
      </ExploreStoreContext.Provider>
    ));
    expect(screen.getByText("function")).toBeDefined();
  });

  it("dispatches proc-select on click", () => {
    const { store, captured } = createTestStore({
      explore: {
        libraries: [], expandedNodes: new Set(), selectedProc: null, selectedDw: null,
        procCache: {}, dwCache: {}, loading: false, activeTab: "source", treeFilter: "",
        highlightedLine: null, leftTab: "objects",
        tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
      },
    });
    render(() => (
      <ExploreStoreContext.Provider value={store}>
        <ProcNode objName="w_main" proc={{ name: "of_init", proc_type: "function", params: "", return_type: "", cyclomatic: null, start_line: null, end_line: null }} depth={1} />
      </ExploreStoreContext.Provider>
    ));
    fireEvent.click(screen.getByText("of_init"));
    const actions = captured.filter(a => a.tag === "explore" && a.action.type === "proc-select");
    expect(actions.length).toBe(1);
  });
});

describe("ObjectNode (datawindow)", () => {
  it("renders DW name with badge and dispatches dw-select on click", () => {
    const { store, captured } = createTestStore({
      explore: {
        libraries: [], expandedNodes: new Set(), selectedProc: null, selectedDw: null,
        procCache: {}, dwCache: {}, loading: false, activeTab: "source", treeFilter: "",
        highlightedLine: null, leftTab: "objects",
        tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
      },
    });
    render(() => (
      <ExploreStoreContext.Provider value={store}>
        <ObjectNode lib="app.pbl" obj={{ name: "d_emp", kind: "datawindow", file: "app.pbl", procedures: [] }} depth={1} />
      </ExploreStoreContext.Provider>
    ));
    expect(screen.getByText("d_emp")).toBeDefined();
    expect(screen.getByText("datawindow")).toBeDefined();
    fireEvent.click(screen.getByText("d_emp"));
    const actions = captured.filter(a => a.tag === "explore" && a.action.type === "dw-select");
    expect(actions.length).toBe(1);
  });
});

describe("ObjectNode", () => {
  it("renders object name and kind badge", () => {
    const { store } = createTestStore({
      explore: {
        libraries: [], expandedNodes: new Set(), selectedProc: null, selectedDw: null,
        procCache: {}, dwCache: {}, loading: false, activeTab: "source", treeFilter: "",
        highlightedLine: null, leftTab: "objects",
        tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
      },
    });
    render(() => (
      <ExploreStoreContext.Provider value={store}>
        <ObjectNode lib="app.pbl" obj={{ name: "w_main", kind: "powerscript", file: "app.pbl", procedures: [] }} depth={1} />
      </ExploreStoreContext.Provider>
    ));
    expect(screen.getByText("w_main")).toBeDefined();
    expect(screen.getByText("powerscript")).toBeDefined();
  });

  it("shows procedure count for non-DW objects", () => {
    const { store } = createTestStore({
      explore: {
        libraries: [], expandedNodes: new Set(), selectedProc: null, selectedDw: null,
        procCache: {}, dwCache: {}, loading: false, activeTab: "source", treeFilter: "",
        highlightedLine: null, leftTab: "objects",
        tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
      },
    });
    render(() => (
      <ExploreStoreContext.Provider value={store}>
        <ObjectNode lib="app.pbl" obj={{ name: "w_main", kind: "powerscript", file: "app.pbl", procedures: [
          { name: "of_init", proc_type: "function", params: "", return_type: "", cyclomatic: null, start_line: null, end_line: null },
          { name: "of_close", proc_type: "subroutine", params: "", return_type: "", cyclomatic: null, start_line: null, end_line: null },
       ] }} depth={1} />
      </ExploreStoreContext.Provider>
    ));
    expect(screen.getByText("2 procedures")).toBeDefined();
  });

  it("hides DW objects when filtered out", () => {
    const { store } = createTestStore({
      explore: {
        libraries: [], expandedNodes: new Set(), selectedProc: null, selectedDw: null,
        procCache: {}, dwCache: {}, loading: false, activeTab: "source", treeFilter: "zzz",
        highlightedLine: null, leftTab: "objects",
        tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
      },
    });
    render(() => (
      <ExploreStoreContext.Provider value={store}>
        <ObjectNode lib="app.pbl" obj={{ name: "d_emp", kind: "datawindow", file: "app.pbl", procedures: [] }} depth={1} />
      </ExploreStoreContext.Provider>
    ));
    expect(screen.queryByText("d_emp")).toBeNull();
  });
});

describe("LibraryNode", () => {
  it("renders library name with object count", () => {
    const { store } = createTestStore({
      explore: {
        libraries: [], expandedNodes: new Set(), selectedProc: null, selectedDw: null,
        procCache: {}, dwCache: {}, loading: false, activeTab: "source", treeFilter: "",
        highlightedLine: null, leftTab: "objects",
        tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
      },
    });
    render(() => (
      <ExploreStoreContext.Provider value={store}>
        <LibraryNode lib={{ name: "app.pbl", objects: [] }} depth={0} />
      </ExploreStoreContext.Provider>
    ));
    expect(screen.getByText("app.pbl")).toBeDefined();
    expect(screen.getByText("0 objects")).toBeDefined();
  });
});
