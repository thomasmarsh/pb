// tests/components/Diagrams.test.tsx — Tests for Diagrams component.

import { describe, it, expect } from "vitest";
import { screen, fireEvent } from "@solidjs/testing-library";
import { renderWithStore } from "../helpers.js";
import { Diagrams } from "../../src/features/diagrams/Diagrams.js";

describe("Diagrams component", () => {
  it("renders Generate button", () => {
    renderWithStore(Diagrams);
    expect(screen.getByText("Generate")).toBeDefined();
  });

  it("Generate button dispatches diagrams/params + diagrams/generate", () => {
    const { captured } = renderWithStore(Diagrams);
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
      diagrams: { active: "inheritance", svg: null, loading: true, params: {}, error: null },
    });
    expect(screen.getByText("Generating diagram...")).toBeDefined();
  });

  it("shows SVG output when available", () => {
    const { container } = renderWithStore(Diagrams, {
      diagrams: { active: "inheritance", svg: '<svg viewBox="0 0 100 100"><rect/></svg>', loading: false, params: {}, error: null },
    });
    const svg = container.querySelector(".diagram-container svg");
    expect(svg).not.toBeNull();
    expect(svg!.getAttribute("viewBox")).toBe("0 0 100 100");
  });

  it("shows error when error exists", () => {
    renderWithStore(Diagrams, {
      diagrams: { active: "inheritance", svg: null, loading: false, params: {}, error: "timeout" },
    });
    expect(screen.getByText("Error: timeout")).toBeDefined();
  });

  it("shows placeholder when no state", () => {
    renderWithStore(Diagrams, {
      diagrams: { active: "inheritance", svg: null, loading: false, params: {}, error: null },
    });
    expect(screen.getByText("Select options and click Generate")).toBeDefined();
  });
});
