// tests/explore/Browser.test.tsx — Tests for the Browser page (Plan 210 Phase 2).

import { describe, it, expect } from "vitest";
import { screen, fireEvent } from "@solidjs/testing-library";
import { renderWithStore } from "../helpers.js";
import { Browser } from "../../app/src/views/features/explore/Browser.js";
import { makeInitialExploreState } from "@pb/platform";

function exploreWithBrowser(overrides?: object) {
  return { ...makeInitialExploreState(), browser: { category: "window", items: [], loading: false, ...overrides } };
}

describe("Browser component", () => {
  it("renders a tab per category", () => {
    renderWithStore(Browser, { explore: exploreWithBrowser() });
    for (const label of ["Application", "DataWindow", "Window", "Menu", "User Object", "Function", "System"]) {
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
});
