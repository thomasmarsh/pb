// tests/explore/TreeNodes.test.tsx — Tests for extracted tree node components.

import { describe, it, expect } from "vitest";
import { screen, fireEvent } from "@solidjs/testing-library";
import { render } from "@solidjs/testing-library";
import { ExploreStoreContext } from "../../app/src/views/features/explore/ExploreContext.js";
import { createTestStore } from "../helpers.js";
import { ProcNode, ObjectNode, LibraryNode } from "../../app/src/views/features/explore/TreeNodes.js";

const DEFAULT_SIDEBAR = {
  sidebarGroups: { sourceTree: true, analysisNav: false },
  sidebarCollapsed: false,
};

const BROWSER_STATE = { category: "application", items: [], loading: false, q: "" };

function makeExploreBase() {
  return {
    libraries: [], expandedNodes: new Set<string>(), selectedProc: null, selectedObject: null,
    highlightedProcName: null, selectedDw: null,
    procCache: {}, dwCache: {}, dwLayoutCache: {}, objectSourceCache: {}, loading: false, activeTab: "source" as const,
    treeFilter: "", highlightedLine: null, helpOverlayOpen: false, browser: BROWSER_STATE, ...DEFAULT_SIDEBAR,
  };
}

describe("ProcNode", () => {
  it("renders procedure name", () => {
    const { store } = createTestStore({ explore: makeExploreBase() });
    render(() => (
      <ExploreStoreContext.Provider value={store}>
        <ProcNode objName="w_main" proc={{ name: "of_init", proc_type: "function", params: "(n)", return_type: "void", cyclomatic: 3, start_line: 10, end_line: 20, object: "w_main", modifiers: null }} depth={1} />
      </ExploreStoreContext.Provider>
    ));
    expect(screen.getByText("of_init")).toBeDefined();
  });

  it("shows proc_type badge", () => {
    const { store } = createTestStore({ explore: makeExploreBase() });
    render(() => (
      <ExploreStoreContext.Provider value={store}>
        <ProcNode objName="w_main" proc={{ name: "of_init", proc_type: "function", params: "", return_type: "", cyclomatic: null, start_line: null, end_line: null, object: "w_main", modifiers: null }} depth={1} />
      </ExploreStoreContext.Provider>
    ));
    expect(screen.getByText("function")).toBeDefined();
  });

  it("dispatches proc-select on click", () => {
    const { store, captured } = createTestStore({ explore: makeExploreBase() });
    render(() => (
      <ExploreStoreContext.Provider value={store}>
        <ProcNode objName="w_main" proc={{ name: "of_init", proc_type: "function", params: "", return_type: "", cyclomatic: null, start_line: null, end_line: null, object: "w_main", modifiers: null }} depth={1} />
      </ExploreStoreContext.Provider>
    ));
    fireEvent.click(screen.getByText("of_init"));
    const actions = captured.filter(a => a.tag === "objects" && a.action.tag === "proc-select");
    expect(actions.length).toBe(1);
  });
});

describe("ObjectNode (datawindow)", () => {
  it("renders DW name with badge and dispatches dw-select on click", () => {
    const { store, captured } = createTestStore({ explore: makeExploreBase() });
    render(() => (
      <ExploreStoreContext.Provider value={store}>
        <ObjectNode lib="app.pbl" obj={{ name: "d_emp", kind: "datawindow", file: "app.pbl", procedures: [] }} depth={1} />
      </ExploreStoreContext.Provider>
    ));
    expect(screen.getByText("d_emp")).toBeDefined();
    expect(screen.getByText("datawindow")).toBeDefined();
    fireEvent.click(screen.getByText("d_emp"));
    const actions = captured.filter(a => a.tag === "explore" && a.action.tag === "dw-select");
    expect(actions.length).toBe(1);
  });
});

describe("ObjectNode", () => {
  it("renders object name and kind badge", () => {
    const { store } = createTestStore({ explore: makeExploreBase() });
    render(() => (
      <ExploreStoreContext.Provider value={store}>
        <ObjectNode lib="app.pbl" obj={{ name: "w_main", kind: "powerscript", file: "app.pbl", procedures: [] }} depth={1} />
      </ExploreStoreContext.Provider>
    ));
    expect(screen.getByText("w_main")).toBeDefined();
    expect(screen.getByText("powerscript")).toBeDefined();
  });

  it("dispatches obj-select on click for non-DW objects", () => {
    const { store, captured } = createTestStore({ explore: makeExploreBase() });
    render(() => (
      <ExploreStoreContext.Provider value={store}>
        <ObjectNode lib="app.pbl" obj={{ name: "w_main", kind: "powerscript", file: "app.pbl", procedures: [] }} depth={1} />
      </ExploreStoreContext.Provider>
    ));
    fireEvent.click(screen.getByText("w_main"));
    const actions = captured.filter(a => a.tag === "objects" && a.action.tag === "select");
    expect(actions.length).toBe(1);
  });

  it("lists procs directly (no kind groups) when expanded", () => {
    const { store } = createTestStore({
      explore: {
        ...makeExploreBase(),
        expandedNodes: new Set(["obj:app.pbl:w_main"]),
      },
    });
    render(() => (
      <ExploreStoreContext.Provider value={store}>
        <ObjectNode lib="app.pbl" obj={{ name: "w_main", kind: "powerscript", file: "app.pbl", procedures: [
          { name: "of_init", proc_type: "function", params: "", return_type: "", cyclomatic: null, start_line: null, end_line: null, object: "w_main", modifiers: null },
          { name: "of_close", proc_type: "subroutine", params: "", return_type: "", cyclomatic: null, start_line: null, end_line: null, object: "w_main", modifiers: null },
        ] }} depth={1} />
      </ExploreStoreContext.Provider>
    ));
    expect(screen.getByText("of_init")).toBeDefined();
    expect(screen.getByText("of_close")).toBeDefined();
    expect(screen.queryByText(/Functions/)).toBeNull();
    expect(screen.queryByText(/Subroutines/)).toBeNull();
    expect(screen.queryByText(/Events/)).toBeNull();
  });

  it("groups control-owned events under a synthetic control node", () => {
    const { store } = createTestStore({
      explore: {
        ...makeExploreBase(),
        expandedNodes: new Set(["obj:app.pbl:w_main", "ctrl:w_main:cb_ok"]),
      },
    });
    render(() => (
      <ExploreStoreContext.Provider value={store}>
        <ObjectNode lib="app.pbl" obj={{ name: "w_main", kind: "powerscript", file: "app.pbl", procedures: [
          { name: "of_init", proc_type: "function", params: "", return_type: "", cyclomatic: null, start_line: null, end_line: null, object: "w_main", owner: "w_main", modifiers: null },
          { name: "clicked", proc_type: "event", params: "", return_type: "", cyclomatic: null, start_line: null, end_line: null, object: "w_main", owner: "cb_ok", modifiers: null },
        ] }} depth={1} />
      </ExploreStoreContext.Provider>
    ));
    expect(screen.getByText("of_init")).toBeDefined();
    expect(screen.getByText("cb_ok")).toBeDefined();
    expect(screen.getByText("clicked")).toBeDefined();
  });

  it("renders procs without an owner field flat (no synthetic control node)", () => {
    const { store } = createTestStore({
      explore: {
        ...makeExploreBase(),
        expandedNodes: new Set(["obj:app.pbl:w_main"]),
      },
    });
    render(() => (
      <ExploreStoreContext.Provider value={store}>
        <ObjectNode lib="app.pbl" obj={{ name: "w_main", kind: "powerscript", file: "app.pbl", procedures: [
          { name: "of_init", proc_type: "function", params: "", return_type: "", cyclomatic: null, start_line: null, end_line: null, object: "w_main", modifiers: null },
        ] }} depth={1} />
      </ExploreStoreContext.Provider>
    ));
    expect(screen.getByText("of_init")).toBeDefined();
  });

  it("hides DW objects when filtered out", () => {
    const { store } = createTestStore({
      explore: { ...makeExploreBase(), treeFilter: "zzz" },
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
    const { store } = createTestStore({ explore: makeExploreBase() });
    render(() => (
      <ExploreStoreContext.Provider value={store}>
        <LibraryNode lib={{ name: "app.pbl", objects: [] }} depth={0} />
      </ExploreStoreContext.Provider>
    ));
    expect(screen.getByText("app.pbl")).toBeDefined();
    expect(screen.getByText("0 objects")).toBeDefined();
  });
});
