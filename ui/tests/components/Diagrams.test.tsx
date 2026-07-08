// tests/components/Diagrams.test.tsx — Tests for Diagrams component.

import { describe, it, expect } from "vitest";
import { screen } from "@solidjs/testing-library";
import { renderWithStore } from "../helpers.js";
import { Diagrams } from "../../app/src/views/features/diagrams/Diagrams.js";

const callsDiagrams = {
  active: "calls" as const,
  svg: null,
  loading: false,
  params: {},
  tableNames: ["customers", "orders"],
  objectNames: ["w_main", "u_helper"],
  itemsLoaded: true,
};

const heatmapDiagrams = {
  active: "heatmap" as const,
  svg: null,
  loading: false,
  params: {},
  tableNames: ["customers"],
  objectNames: ["w_main"],
  itemsLoaded: true,
};

const fkGraphDiagrams = {
  active: "fk-graph" as const,
  svg: null,
  loading: false,
  params: {},
  tableNames: ["usrgroups"],
  objectNames: ["w_main"],
  itemsLoaded: true,
};

describe("Diagrams component", () => {
  it("shows loading state when loading", () => {
    renderWithStore(Diagrams, {
      diagrams: { ...callsDiagrams, loading: true },
    });
    expect(screen.getByText("Generating diagram...")).toBeDefined();
  });

  it("shows SVG output with copy/download icon buttons", () => {
    const { container } = renderWithStore(Diagrams, {
      diagrams: { ...callsDiagrams, svg: '<svg viewBox="0 0 100 100"><rect/></svg>' },
    });
    const svg = container.querySelector(".diagram-container svg");
    expect(svg).not.toBeNull();
    expect(svg!.getAttribute("viewBox")).toBe("0 0 100 100");
    const iconBtns = container.querySelectorAll(".icon-btn");
    expect(iconBtns.length).toBe(2);
  });

  it("hides Generate button for auto-generate diagrams", () => {
    renderWithStore(Diagrams, { diagrams: { ...heatmapDiagrams } });
    expect(screen.queryByText("Generate")).toBeNull();
  });

  it("shows error when error exists", () => {
    renderWithStore(Diagrams, {
      diagrams: { ...callsDiagrams, error: "timeout" },
    });
    expect(screen.getByText("Error: timeout")).toBeDefined();
  });

  it("shows placeholder when no svg and not loading", () => {
    const { container } = renderWithStore(Diagrams, {
      diagrams: { ...callsDiagrams, active: "dw-tables" },
    });
    expect(container.querySelector(".diagram-container")).toBeDefined();
  });

  it("includes an fk-graph tab and hides Generate button for it (auto-generate)", () => {
    renderWithStore(Diagrams, { diagrams: { ...fkGraphDiagrams } });
    expect(screen.getByText("fk-graph")).toBeDefined();
    expect(screen.queryByText("Generate")).toBeNull();
  });

  it("deep-links to route.kind on mount, selecting and auto-generating it", () => {
    const { captured } = renderWithStore(Diagrams, {
      nav: {
        route: { view: "diagrams", kind: "fk-graph" },
        crumbs: [],
        history: [{ view: "diagrams", kind: "fk-graph" }],
        historyIdx: 0,
        askContext: null,
      },
      diagrams: { ...heatmapDiagrams, active: "inheritance" },
    });
    expect(captured).toContainEqual({ tag: "diagrams", action: { tag: "select", kind: "fk-graph" } });
    expect(captured).toContainEqual({ tag: "diagrams", action: { tag: "generate" } });
  });

  it("does not re-select when route.kind already matches the active tab", () => {
    const { captured } = renderWithStore(Diagrams, {
      nav: {
        route: { view: "diagrams", kind: "fk-graph" },
        crumbs: [],
        history: [{ view: "diagrams", kind: "fk-graph" }],
        historyIdx: 0,
        askContext: null,
      },
      diagrams: { ...fkGraphDiagrams },
    });
    const selectActions = captured.filter((a) => a.tag === "diagrams" && a.action.tag === "select");
    expect(selectActions.length).toBe(0);
  });

  it("ignores a diagrams route with no kind (existing behavior)", () => {
    const { captured } = renderWithStore(Diagrams, { diagrams: { ...callsDiagrams } });
    const selectActions = captured.filter((a) => a.tag === "diagrams" && a.action.tag === "select");
    expect(selectActions.length).toBe(0);
  });
});
