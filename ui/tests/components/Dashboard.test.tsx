// tests/components/Dashboard.test.tsx — Tests for Dashboard component.

import { describe, it, expect } from "vitest";
import { screen, fireEvent } from "@solidjs/testing-library";
import { renderWithStore } from "../helpers.js";
import { Dashboard } from "../../src/features/dashboard/Dashboard.js";

const sampleStats = {
  objects: 150,
  procedures: 400,
  inherits: 120,
  calls: 800,
  dw_controls: 350,
  by_kind: [
    { kind: "powerscript", count: 100 },
    { kind: "datawindow", count: 50 },
  ],
  top_complex: [
    { object: "w_main", name: "of_init", proc_type: "function", cyclomatic: 25 },
    { object: "w_main", name: "of_save", proc_type: "subroutine", cyclomatic: 18 },
  ],
  top_pagerank: [
    { object: "w_base", pagerank: 0.05, in_degree: 30, out_degree: 10 },
    { object: "w_main", pagerank: 0.03, in_degree: 20, out_degree: 15 },
  ],
};

describe("Dashboard component", () => {
  it("shows loading when stats is null", () => {
    renderWithStore(Dashboard, {
      dashboard: { stats: null },
    });
    expect(screen.getByText("Loading...")).toBeDefined();
  });

  it("renders metrics grid when stats available", () => {
    renderWithStore(Dashboard, {
      dashboard: { stats: sampleStats },
    });
    expect(screen.getByText("Objects")).toBeDefined();
    expect(screen.getByText("150")).toBeDefined();
    expect(screen.getByText("Procedures")).toBeDefined();
    expect(screen.getByText("400")).toBeDefined();
  });

  it("renders object types table", () => {
    renderWithStore(Dashboard, {
      dashboard: { stats: sampleStats },
    });
    expect(screen.getByText("Object Types")).toBeDefined();
    expect(screen.getByText("powerscript")).toBeDefined();
    expect(screen.getByText("100")).toBeDefined();
  });

  it("renders most complex procedures table", () => {
    renderWithStore(Dashboard, {
      dashboard: { stats: sampleStats },
    });
    expect(screen.getByText("Most Complex Procedures")).toBeDefined();
    expect(screen.getByText("of_init")).toBeDefined();
    expect(screen.getByText("of_save")).toBeDefined();
  });

  it("clicking procedure row dispatches proc-select", () => {
    const { captured } = renderWithStore(Dashboard, {
      dashboard: { stats: sampleStats },
    });
    fireEvent.click(screen.getByText("of_init"));
    const procSelectActions = captured.filter(
      (a) => a.tag === "objects" && a.action.type === "proc-select",
    );
    expect(procSelectActions.length).toBe(1);
  });

  it("renders most important objects table", () => {
    renderWithStore(Dashboard, {
      dashboard: { stats: sampleStats },
    });
    expect(screen.getByText("Most Important Objects (PageRank)")).toBeDefined();
    expect(screen.getByText("w_base")).toBeDefined();
  });

  it("clicking object row dispatches select", () => {
    const { captured } = renderWithStore(Dashboard, {
      dashboard: { stats: sampleStats },
    });
    fireEvent.click(screen.getByText("w_base"));
    const selectActions = captured.filter(
      (a) => a.tag === "objects" && a.action.type === "select",
    );
    expect(selectActions.length).toBe(1);
  });
});
