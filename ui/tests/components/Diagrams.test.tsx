// tests/components/Diagrams.test.tsx — Tests for Diagrams component.

import { describe, it, expect } from "vitest";
import { screen, fireEvent } from "@solidjs/testing-library";
import { renderWithStore } from "../helpers.js";
import { Diagrams } from "../../src/features/diagrams/Diagrams.js";

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
    renderWithStore(Diagrams, { diagrams: heatmapDiagrams });
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
});
