// tests/components/Dashboard.test.tsx — Tests for Dashboard component.

import { describe, it, expect, vi, afterEach } from "vitest";
import { screen, fireEvent, render, cleanup } from "@solidjs/testing-library";
import { renderWithStore } from "../helpers.js";
import { Dashboard } from "../../src/features/dashboard/Dashboard.js";
import { createStore, Effect } from "@pb/core";
import { reducer, initialState } from "../../src/features/app/reducer.js";
import { initialDashboardState } from "@pb/platform";
import { mockEnv } from "../helpers.js";
import type { AppEnv } from "../../src/features/app/reducer.js";
import type { StatsResponse } from "@pb/platform";

const sampleStats: StatsResponse = {
  objects: 150,
  procedures: 400,
  inherits: 120,
  calls: 800,
  dw_controls: 350,
  dw_retrieve_tables: 50,
  dw_retrieve_columns: 120,
  object_metrics: 150,
  tables: 45,
  by_kind: [
    { kind: "powerscript", count: 100 },
    { kind: "datawindow", count: 50 },
  ],
  top_complex: [
    { object: "w_main", name: "of_init", proc_type: "function", cyclomatic: 25, modifiers: null, params: null, return_type: null, start_line: null, end_line: null },
    { object: "w_main", name: "of_save", proc_type: "subroutine", cyclomatic: 18, modifiers: null, params: null, return_type: null, start_line: null, end_line: null },
  ],
  top_pagerank: [
    { object: "w_base", pagerank: 0.05, in_degree: 30, out_degree: 10 },
    { object: "w_main", pagerank: 0.03, in_degree: 20, out_degree: 15 },
  ],
};

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe("Dashboard component", () => {
  it("shows loading when stats is null", () => {
    renderWithStore(Dashboard, {
      dashboard: { ...initialDashboardState, stats: null },
    });
    expect(screen.getByText("Loading...")).toBeDefined();
  });

  it("renders metrics grid when stats available", () => {
    renderWithStore(Dashboard, {
      dashboard: { ...initialDashboardState, stats: sampleStats },
    });
    expect(screen.getByText("Objects")).toBeDefined();
    expect(screen.getByText("150")).toBeDefined();
    expect(screen.getByText("Procedures")).toBeDefined();
    expect(screen.getByText("400")).toBeDefined();
  });

  it("renders object types table", () => {
    renderWithStore(Dashboard, {
      dashboard: { ...initialDashboardState, stats: sampleStats },
    });
    expect(screen.getByText("Object Types")).toBeDefined();
    expect(screen.getByText("powerscript")).toBeDefined();
    expect(screen.getByText("100")).toBeDefined();
  });

  it("renders most complex procedures table", () => {
    renderWithStore(Dashboard, {
      dashboard: { ...initialDashboardState, stats: sampleStats },
    });
    expect(screen.getByText("Most Complex Procedures")).toBeDefined();
    expect(screen.getByText("of_init")).toBeDefined();
    expect(screen.getByText("of_save")).toBeDefined();
  });

  it("clicking procedure row dispatches proc-select", () => {
    const { captured } = renderWithStore(Dashboard, {
      dashboard: { ...initialDashboardState, stats: sampleStats },
    });
    fireEvent.click(screen.getByText("of_init"));
    const procSelectActions = captured.filter(
      (a) => a.tag === "objects" && a.action.tag === "proc-select",
    );
    expect(procSelectActions.length).toBe(1);
  });

  it("renders complexity heatmap section", async () => {
    const env = { ...mockEnv, getDiagram: () => Effect.send('<svg id="heatmap-svg"></svg>') } as AppEnv;
    const state = { ...initialState(), dashboard: { ...initialDashboardState, stats: sampleStats } };
    const store = createStore(state, reducer, env);
    const { container } = render(() => <Dashboard store={store} />);
    await vi.waitUntil(() => container.querySelector("#heatmap-svg") != null);
    const headers = [...container.querySelectorAll(".card-header h2")];
    expect(headers.some((h) => h.textContent === "Complexity Heatmap")).toBe(true);
  });

  it("renders most important objects table", () => {
    renderWithStore(Dashboard, {
      dashboard: { ...initialDashboardState, stats: sampleStats },
    });
    expect(screen.getByText("Most Important Objects (PageRank)")).toBeDefined();
    expect(screen.getByText("w_base")).toBeDefined();
  });

  it("clicking object row dispatches select", () => {
    const { captured } = renderWithStore(Dashboard, {
      dashboard: { ...initialDashboardState, stats: sampleStats },
    });
    fireEvent.click(screen.getByText("w_base"));
    const selectActions = captured.filter(
      (a) => a.tag === "objects" && a.action.tag === "select",
    );
    expect(selectActions.length).toBe(1);
  });
});
