// tests/components/Diagrams.test.tsx — Tests for Diagrams component.

import { describe, it, expect } from "vitest";
import { screen } from "@solidjs/testing-library";
import { initialJobPollState } from "@pb/core";
import { renderWithStore } from "../helpers.js";
import { Diagrams } from "../../app/src/views/features/diagrams/Diagrams.js";

const callsDiagrams = {
  active: "calls" as const,
  job: initialJobPollState<string>(),
  params: {},
  tableNames: ["customers", "orders"],
  objectNames: ["w_main", "u_helper"],
  itemsLoaded: true,
};

const heatmapDiagrams = {
  active: "heatmap" as const,
  job: initialJobPollState<string>(),
  params: {},
  tableNames: ["customers"],
  objectNames: ["w_main"],
  itemsLoaded: true,
};

const fkGraphDiagrams = {
  active: "fk-graph" as const,
  job: initialJobPollState<string>(),
  params: {},
  tableNames: ["usrgroups"],
  objectNames: ["w_main"],
  itemsLoaded: true,
};

describe("Diagrams component", () => {
  it("shows loading state when loading", () => {
    renderWithStore(Diagrams, {
      diagrams: { ...callsDiagrams, job: { ...initialJobPollState<string>(), status: "pending" } },
    });
    expect(screen.getByText("Generating diagram...")).toBeDefined();
  });

  it("shows SVG output with zoom, copy and download icon buttons", () => {
    const { container } = renderWithStore(Diagrams, {
      diagrams: { ...callsDiagrams, job: { ...initialJobPollState<string>(), status: "done", result: '<svg viewBox="0 0 100 100"><rect/></svg>' } },
    });
    // Scoped to the pan/zoom wrapper: the toolbar's own icons are <svg> too.
    const svg = container.querySelector(".diagram-svg-wrap svg");
    expect(svg).not.toBeNull();
    expect(svg!.getAttribute("viewBox")).toBe("0 0 100 100");
    const iconBtns = container.querySelectorAll(".icon-btn");
    expect(iconBtns.length).toBe(5); // zoom out, zoom in, 1:1, copy, download
  });

  it("renders the lattice in a taller viewport", () => {
    const svg = '<svg viewBox="0 0 100 100"><rect/></svg>';
    const { container } = renderWithStore(Diagrams, {
      diagrams: { ...callsDiagrams, active: "window-table-lattice", job: { ...initialJobPollState<string>(), status: "done", result: svg } },
    });
    expect(container.querySelector(".diagram-viewport.tall")).not.toBeNull();
  });

  it("hides Generate button for auto-generate diagrams", () => {
    renderWithStore(Diagrams, { diagrams: { ...heatmapDiagrams } });
    expect(screen.queryByText("Generate")).toBeNull();
  });

  it("shows error when error exists", () => {
    renderWithStore(Diagrams, {
      diagrams: { ...callsDiagrams, job: { ...initialJobPollState<string>(), status: "error", error: "timeout" } },
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
