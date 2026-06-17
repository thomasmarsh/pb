// tests/components/Diagrams.test.tsx — Tests for Diagrams component.

import { describe, it, expect } from "vitest";
import { screen, fireEvent } from "@solidjs/testing-library";
import { renderWithStore } from "../helpers.js";
import { Diagrams } from "../../src/features/diagrams/Diagrams.js";

const defaultDiagrams = {
  active: "inheritance" as const,
  svg: null,
  loading: false,
  params: {},
  tableNames: ["customers", "orders"],
  objectNames: ["w_main", "u_helper"],
  itemsLoaded: true,
};

describe("Diagrams component", () => {
  it("renders Generate button", () => {
    renderWithStore(Diagrams, { diagrams: defaultDiagrams });
    expect(screen.getByText("Generate")).toBeDefined();
  });

  it("Generate button dispatches diagrams/params + diagrams/generate", () => {
    const { captured } = renderWithStore(Diagrams, { diagrams: defaultDiagrams });
    fireEvent.click(screen.getByText("Generate"));
    const paramsActions = captured.filter(
      (a) => a.tag === "diagrams" && a.action.type === "params",
    );
    const generateActions = captured.filter(
      (a) => a.tag === "diagrams" && a.action.type === "generate",
    );
    expect(paramsActions.length).toBe(1);
    expect(generateActions.length).toBe(1);
  });

  it("shows loading state when loading", () => {
    renderWithStore(Diagrams, {
      diagrams: { ...defaultDiagrams, loading: true },
    });
    expect(screen.getByText("Generating diagram...")).toBeDefined();
  });

  it("shows SVG output when available", () => {
    const { container } = renderWithStore(Diagrams, {
      diagrams: { ...defaultDiagrams, svg: '<svg viewBox="0 0 100 100"><rect/></svg>' },
    });
    const svg = container.querySelector(".diagram-container svg");
    expect(svg).not.toBeNull();
    expect(svg!.getAttribute("viewBox")).toBe("0 0 100 100");
  });

  it("shows error when error exists", () => {
    renderWithStore(Diagrams, {
      diagrams: { ...defaultDiagrams, error: "timeout" },
    });
    expect(screen.getByText("Error: timeout")).toBeDefined();
  });

  it("shows placeholder when no state", () => {
    const { container } = renderWithStore(Diagrams, {
      diagrams: defaultDiagrams,
    });
    expect(container.querySelector(".diagram-container")).toBeDefined();
    expect(screen.getByText("Generate")).toBeDefined();
  });
});
