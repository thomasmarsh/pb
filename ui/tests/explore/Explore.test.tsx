// tests/components/Explore.test.tsx — Tests for Explore component.

import { describe, it, expect } from "vitest";
import { screen, fireEvent } from "@solidjs/testing-library";
import { renderWithStore } from "../helpers.js";
import { Explore } from "../../src/features/explore/Explore.js";

const sampleLibraries = [
  {
    name: "app.pbl",
    objects: [
      { name: "w_main", kind: "powerscript", file: "app.pbl", procedures: [
        { name: "of_init", proc_type: "function", params: "", return_type: "", cyclomatic: 5, start_line: 10 },
      ] },
      { name: "d_emp", kind: "datawindow", file: "app.pbl", procedures: [] },
    ],
  },
];

describe("Explore component", () => {
  it("renders AST Explorer heading", () => {
    renderWithStore(Explore, {
      explore: {
        libraries: sampleLibraries, expandedNodes: new Set(), selectedProc: null, selectedDw: null,
        procCache: {}, dwCache: {}, loading: false, activeTab: "source", treeFilter: "",
        highlightedLine: null, leftTab: "objects",
        tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
      },
    });
    expect(screen.getByText("AST Explorer")).toBeDefined();
  });

  it("renders Objects/Tables tabs", () => {
    renderWithStore(Explore, {
      explore: {
        libraries: [], expandedNodes: new Set(), selectedProc: null, selectedDw: null,
        procCache: {}, dwCache: {}, loading: false, activeTab: "source", treeFilter: "",
        highlightedLine: null, leftTab: "objects",
        tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
      },
    });
    expect(screen.getByText("Objects")).toBeDefined();
    expect(screen.getByText("Tables")).toBeDefined();
  });

  it("renders Expand All and Collapse All buttons", () => {
    renderWithStore(Explore, {
      explore: {
        libraries: [], expandedNodes: new Set(), selectedProc: null, selectedDw: null,
        procCache: {}, dwCache: {}, loading: false, activeTab: "source", treeFilter: "",
        highlightedLine: null, leftTab: "objects",
        tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
      },
    });
    expect(screen.getByText("Expand All")).toBeDefined();
    expect(screen.getByText("Collapse All")).toBeDefined();
  });

  it("Expand All dispatches explore/expand-all", () => {
    const { captured } = renderWithStore(Explore, {
      explore: {
        libraries: sampleLibraries, expandedNodes: new Set(), selectedProc: null, selectedDw: null,
        procCache: {}, dwCache: {}, loading: false, activeTab: "source", treeFilter: "",
        highlightedLine: null, leftTab: "objects",
        tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
      },
    });
    fireEvent.click(screen.getByText("Expand All"));
    const expandActions = captured.filter(
      (a) => a.tag === "explore" && a.action.type === "expand-all",
    );
    expect(expandActions.length).toBe(1);
  });

  it("Collapse All dispatches explore/collapse-all", () => {
    const { captured } = renderWithStore(Explore, {
      explore: {
        libraries: sampleLibraries, expandedNodes: new Set(["lib:app.pbl"]), selectedProc: null, selectedDw: null,
        procCache: {}, dwCache: {}, loading: false, activeTab: "source", treeFilter: "",
        highlightedLine: null, leftTab: "objects",
        tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
      },
    });
    fireEvent.click(screen.getByText("Collapse All"));
    const collapseActions = captured.filter(
      (a) => a.tag === "explore" && a.action.type === "collapse-all",
    );
    expect(collapseActions.length).toBe(1);
  });

  it("filter input dispatches explore/filter", () => {
    const { captured } = renderWithStore(Explore, {
      explore: {
        libraries: [], expandedNodes: new Set(), selectedProc: null, selectedDw: null,
        procCache: {}, dwCache: {}, loading: false, activeTab: "source", treeFilter: "",
        highlightedLine: null, leftTab: "objects",
        tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
      },
    });
    const input = screen.getByPlaceholderText(/Filter/);
    fireEvent.input(input, { target: { value: "w_" } });
    const filterActions = captured.filter(
      (a) => a.tag === "explore" && a.action.type === "filter",
    );
    expect(filterActions.length).toBe(1);
  });

  it("shows loading when loading and no libraries", () => {
    renderWithStore(Explore, {
      explore: {
        libraries: [], expandedNodes: new Set(), selectedProc: null, selectedDw: null,
        procCache: {}, dwCache: {}, loading: true, activeTab: "source", treeFilter: "",
        highlightedLine: null, leftTab: "objects",
        tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
      },
    });
    expect(screen.getByText(/Loading AST tree/)).toBeDefined();
  });

  it("shows empty state when no libraries and not loading", () => {
    renderWithStore(Explore, {
      explore: {
        libraries: [], expandedNodes: new Set(), selectedProc: null, selectedDw: null,
        procCache: {}, dwCache: {}, loading: false, activeTab: "source", treeFilter: "",
        highlightedLine: null, leftTab: "objects",
        tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
      },
    });
    expect(screen.getByText(/No data/)).toBeDefined();
  });

  it("renders library nodes when libraries exist", () => {
    renderWithStore(Explore, {
      explore: {
        libraries: sampleLibraries, expandedNodes: new Set(), selectedProc: null, selectedDw: null,
        procCache: {}, dwCache: {}, loading: false, activeTab: "source", treeFilter: "",
        highlightedLine: null, leftTab: "objects",
        tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
      },
    });
    expect(screen.getByText("app.pbl")).toBeDefined();
  });

  it("shows 'Select a procedure or DataWindow' in detail panel", () => {
    renderWithStore(Explore, {
      explore: {
        libraries: sampleLibraries, expandedNodes: new Set(), selectedProc: null, selectedDw: null,
        procCache: {}, dwCache: {}, loading: false, activeTab: "source", treeFilter: "",
        highlightedLine: null, leftTab: "objects",
        tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
      },
    });
    expect(screen.getByText("Select a procedure or DataWindow")).toBeDefined();
  });
});
