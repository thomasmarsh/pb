// tests/explore/Explore.test.tsx — Tests for the Explore detail panel component.

import { describe, it, expect } from "vitest";
import { screen } from "@solidjs/testing-library";
import { renderWithStore } from "../helpers.js";
import { Explore } from "../../app/src/views/features/explore/Explore.js";

const DEFAULT_SIDEBAR = {
  sidebarGroups: { sourceTree: true, analysisNav: false },
  sidebarCollapsed: false,
};

const BROWSER_STATE = { category: "application", items: [], loading: false, q: "" };

const sampleLibraries = [
  {
    name: "app.pbl",
    objects: [
      { name: "w_main", kind: "powerscript", file: "app.pbl", procedures: [
        { name: "of_init", proc_type: "function", params: "", return_type: "", cyclomatic: 5, start_line: 10, object: "w_main", modifiers: null, end_line: 50 },
      ] },
      { name: "d_emp", kind: "datawindow", file: "app.pbl", procedures: [] },
    ],
  },
];

function makeExplore(overrides?: object) {
  return {
    libraries: sampleLibraries, expandedNodes: new Set<string>(), selectedProc: null,
    selectedObject: null, highlightedProcName: null, selectedDw: null,
    procCache: {}, dwCache: {}, dwLayoutCache: {}, objectSourceCache: {}, loading: false, activeTab: "source" as const,
    treeFilter: "", highlightedLine: null, browser: BROWSER_STATE, helpOverlayOpen: false, ...DEFAULT_SIDEBAR, ...overrides,
  };
}

describe("Explore detail panel", () => {
  it("shows empty state when nothing is selected", () => {
    renderWithStore(Explore, { explore: makeExplore() });
    expect(screen.getByText("Select an object or DataWindow")).toBeDefined();
  });
});
