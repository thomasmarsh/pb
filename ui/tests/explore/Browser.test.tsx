// tests/explore/Browser.test.tsx — Tests for the Browser page (Plan 210
// Phase 2 + Plan 211 Phase B consolidation).

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { screen, fireEvent } from "@solidjs/testing-library";
import { renderWithStore } from "../helpers.js";
import { Browser } from "../../app/src/views/features/explore/Browser.js";
import { makeInitialExploreState, initialSearchState, initialTablesState, initialObjectsState } from "@pb/platform";
import type { SearchResponse } from "@pb/platform";

function exploreWithBrowser(overrides?: object) {
  return { ...makeInitialExploreState(), browser: { category: "window", items: [], loading: false, q: "", ...overrides } };
}

describe("Browser component", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("renders a tab per category, including All/Tables/Procedures", () => {
    renderWithStore(Browser, { explore: exploreWithBrowser() });
    for (const label of [
      "All", "Application", "DataWindow", "Window", "Menu", "User Object",
      "Function", "System", "Structure", "Tables", "Procedures",
    ]) {
      expect(screen.getByText(label)).toBeDefined();
    }
  });

  it("dispatches browser-tab when a tab is clicked", () => {
    const { captured } = renderWithStore(Browser, { explore: exploreWithBrowser() });
    fireEvent.click(screen.getByText("Menu"));
    const actions = captured.filter(a => a.tag === "explore" && a.action.tag === "browser-tab" && a.action.category === "menu");
    expect(actions.length).toBe(1);
  });

  it("shows empty state when no items for the active category", () => {
    renderWithStore(Browser, { explore: exploreWithBrowser() });
    expect(screen.getByText("No Window objects.")).toBeDefined();
  });

  it("renders items and dispatches select on click for non-DW objects", () => {
    const { captured } = renderWithStore(Browser, {
      explore: exploreWithBrowser({
        items: [{ name: "w_main", kind: "powerscript", category: "window", file: "app.pbl", ancestor: null }],
      }),
    });
    expect(screen.getByText("w_main")).toBeDefined();
    fireEvent.click(screen.getByText("w_main"));
    const actions = captured.filter(a => a.tag === "objects" && a.action.tag === "select");
    expect(actions.length).toBe(1);
  });

  it("dispatches dw-select on click for datawindow objects", () => {
    const { captured } = renderWithStore(Browser, {
      explore: exploreWithBrowser({
        category: "datawindow",
        items: [{ name: "d_emp", kind: "datawindow", category: "datawindow", file: "app.pbl", ancestor: null }],
      }),
    });
    fireEvent.click(screen.getByText("d_emp"));
    const actions = captured.filter(a => a.tag === "explore" && a.action.tag === "dw-select");
    expect(actions.length).toBe(1);
  });

  it("All tab falls back to the plain object list when the query is under 2 chars", () => {
    renderWithStore(Browser, {
      explore: exploreWithBrowser({
        category: "all",
        items: [{ name: "w_main", kind: "powerscript", category: "window", file: "app.pbl", ancestor: null }],
      }),
    });
    expect(screen.getByText("w_main")).toBeDefined();
  });

  it("All tab renders BrowserSearchResults once a 2+ char term already has results", () => {
    const results: SearchResponse = {
      objects: [{ name: "w_login", kind: "powerscript", category: "window", file: "app.pbl", ancestor: null }],
      procedures: [], datawindows: [], tables: [],
    };
    renderWithStore(Browser, {
      explore: exploreWithBrowser({ category: "all" }),
      search: { ...initialSearchState, term: "fn", results },
    });
    expect(screen.getByText("Objects (1)")).toBeDefined();
    expect(screen.getByText("w_login")).toBeDefined();
  });

  it("typing 2+ chars in the All tab dispatches a debounced search/term", async () => {
    const { captured } = renderWithStore(Browser, { explore: exploreWithBrowser({ category: "all" }) });
    const input = screen.getByPlaceholderText("Search everything...");
    fireEvent.input(input, { target: { value: "fn" } });
    await vi.advanceTimersByTimeAsync(350);
    const searchActions = captured.filter(a => a.tag === "search" && a.action.tag === "term");
    expect(searchActions.length).toBe(1);
    expect(searchActions[0]).toEqual({ tag: "search", action: { tag: "term", term: "fn" } });
  });

  it("Tables tab renders embedded TableList with a single shared search input", () => {
    renderWithStore(Browser, {
      explore: exploreWithBrowser({ category: "tables" }),
      tables: { ...initialTablesState },
    });
    expect(screen.getByText("No tables found.")).toBeDefined();
    expect(document.querySelectorAll("input.search-input").length).toBe(1);
  });

  it("Procedures tab renders embedded ProceduresList with a single shared search input", () => {
    renderWithStore(Browser, {
      explore: exploreWithBrowser({ category: "procedures" }),
      objects: { ...initialObjectsState, proceduresList: [] },
    });
    expect(screen.getByText("No procedures found.")).toBeDefined();
    expect(document.querySelectorAll("input.search-input").length).toBe(1);
  });

  it("typing in the Tables tab dispatches tables/filter", () => {
    const { captured } = renderWithStore(Browser, {
      explore: exploreWithBrowser({ category: "tables" }),
      tables: { ...initialTablesState },
    });
    const input = screen.getByPlaceholderText("Search tables…");
    fireEvent.input(input, { target: { value: "us" } });
    const actions = captured.filter(a => a.tag === "tables" && a.action.tag === "filter");
    expect(actions.length).toBe(1);
    expect(actions[0]).toEqual({ tag: "tables", action: { tag: "filter", q: "us" } });
  });

  it("typing in the Procedures tab dispatches objects/procs-list-filter", () => {
    const { captured } = renderWithStore(Browser, {
      explore: exploreWithBrowser({ category: "procedures" }),
      objects: { ...initialObjectsState, proceduresList: [] },
    });
    const input = screen.getByPlaceholderText("Search procedures or objects…");
    fireEvent.input(input, { target: { value: "of_" } });
    const actions = captured.filter(a => a.tag === "objects" && a.action.tag === "procs-list-filter");
    expect(actions.length).toBe(1);
    expect(actions[0]).toEqual({ tag: "objects", action: { tag: "procs-list-filter", q: "of_" } });
  });

  it("typing in a generic category tab dispatches a debounced explore/browser-filter", async () => {
    const { captured } = renderWithStore(Browser, { explore: exploreWithBrowser({ category: "window" }) });
    const input = screen.getByPlaceholderText("Search Window…");
    fireEvent.input(input, { target: { value: "w_" } });
    await vi.advanceTimersByTimeAsync(350);
    const actions = captured.filter(a => a.tag === "explore" && a.action.tag === "browser-filter");
    expect(actions.length).toBe(1);
    expect(actions[0]).toEqual({ tag: "explore", action: { tag: "browser-filter", q: "w_" } });
  });
});
