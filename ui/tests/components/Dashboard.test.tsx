// tests/components/Dashboard.test.tsx — Tests for Dashboard component.

import { describe, it, expect, vi, afterEach } from "vitest";
import { screen, fireEvent, render, cleanup } from "@solidjs/testing-library";
import { renderWithStore } from "../helpers.js";
import { Dashboard } from "../../app/src/views/features/dashboard/Dashboard.js";
import { createStore, Effect } from "@pb/core";
import { reducer, initialState } from "../../app/src/reducer.js";
import { initialDashboardState } from "@pb/platform";
import { mockEnv } from "../helpers.js";
import type { AppEnv } from "../../app/src/reducer.js";
import type { AppAction } from "../../app/src/actions.js";
import type { StatsResponse, CodeQualityReportResponse } from "@pb/platform";

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
  ddl_loaded: true,
  unenforced_fk_count: 5,
  unused_fk_count: 36,
  corroborated_fk_count: 47,
  dead_column_count: 4,
  co_update_pair_count: 45,
  co_update_violation_count: 0,
};

const sampleReport: CodeQualityReportResponse = {
  top_complexity_procedures: [
    { object: "w_main", proc_name: "of_init", proc_type: "function", cyclomatic: 25 },
  ],
  dead_procedures_by_object: [
    { object: "w_zzzdead", dead_count: 42 },
    { object: "w_yyydead", dead_count: 17 },
  ],
  taint_severity_distribution: [
    { severity: "critical", count: 9 },
    { severity: "medium", count: 3 },
  ],
  sql_statement_complexity_histogram: [
    { table_count: 1, statement_count: 13 },
    { table_count: 3, statement_count: 6 },
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
    const env = { ...mockEnv, submitDiagramJob: () => Effect.send({ status: "done" as const, result: '<svg id="heatmap-svg"></svg>' }) } as AppEnv;
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

  it("renders unenforced FKs and dead columns tiles when ddl_loaded", () => {
    renderWithStore(Dashboard, {
      dashboard: { ...initialDashboardState, stats: sampleStats },
    });
    expect(screen.getByText("Unenforced FKs")).toBeDefined();
    expect(screen.getByText("5")).toBeDefined();
    expect(screen.getByText("Dead Columns")).toBeDefined();
    expect(screen.getByText("4")).toBeDefined();
  });

  it("renders Schema Integrity capability row when ddl_loaded", () => {
    renderWithStore(Dashboard, {
      dashboard: { ...initialDashboardState, stats: sampleStats },
    });
    expect(screen.getByText("Schema Integrity")).toBeDefined();
    expect(screen.getByText("47 corroborated FKs · 5 unenforced · 0 co-update violations")).toBeDefined();
  });

  it("clicking Unenforced FKs tile deep-links to the fk-graph diagram", () => {
    const { captured } = renderWithStore(Dashboard, {
      dashboard: { ...initialDashboardState, stats: sampleStats },
    });
    fireEvent.click(screen.getByText("Unenforced FKs"));
    expect(captured).toContainEqual({
      tag: "nav",
      action: { tag: "navigate", route: { view: "diagrams", kind: "fk-graph" } },
    });
  });

  it("clicking Schema Integrity row's View link deep-links to the fk-graph diagram", () => {
    const { captured, container } = renderWithStore(Dashboard, {
      dashboard: { ...initialDashboardState, stats: sampleStats },
    });
    const rows = [...container.querySelectorAll(".phase-health-row")];
    const schemaRow = rows.find((r) => r.textContent?.includes("Schema Integrity"));
    expect(schemaRow).toBeDefined();
    fireEvent.click(schemaRow!.querySelector(".phase-health-link")!);
    expect(captured).toContainEqual({
      tag: "nav",
      action: { tag: "navigate", route: { view: "diagrams", kind: "fk-graph" } },
    });
  });

  it("renders dead-procedures-by-object card from the code quality report", async () => {
    const env = { ...mockEnv, getCodeQualityReport: () => Effect.send(sampleReport) } as AppEnv;
    const state = { ...initialState(), dashboard: { ...initialDashboardState, stats: sampleStats } };
    const store = createStore(state, reducer, env);
    render(() => <Dashboard store={store} />);
    await vi.waitUntil(() => screen.queryByText("w_zzzdead") != null);
    expect(screen.getByText("Dead Procedures by Object")).toBeDefined();
    expect(screen.getByText("w_zzzdead")).toBeDefined();
    expect(screen.getByText("42")).toBeDefined();
  });

  it("renders taint severity distribution card from the code quality report", async () => {
    const env = { ...mockEnv, getCodeQualityReport: () => Effect.send(sampleReport) } as AppEnv;
    const state = { ...initialState(), dashboard: { ...initialDashboardState, stats: sampleStats } };
    const store = createStore(state, reducer, env);
    render(() => <Dashboard store={store} />);
    await vi.waitUntil(() => screen.queryByText("Taint Severity Distribution") != null);
    expect(screen.getByText("critical")).toBeDefined();
    expect(screen.getByText("9")).toBeDefined();
  });

  it("renders SQL statement complexity histogram card from the code quality report", async () => {
    const env = { ...mockEnv, getCodeQualityReport: () => Effect.send(sampleReport) } as AppEnv;
    const state = { ...initialState(), dashboard: { ...initialDashboardState, stats: sampleStats } };
    const store = createStore(state, reducer, env);
    render(() => <Dashboard store={store} />);
    await vi.waitUntil(() => screen.queryByText("SQL Statement Complexity") != null);
    expect(screen.getByText("13")).toBeDefined();
    expect(screen.getByText("6")).toBeDefined();
  });

  it("clicking a dead-procedures-by-object row dispatches objects select", async () => {
    const env = { ...mockEnv, getCodeQualityReport: () => Effect.send(sampleReport) } as AppEnv;
    const state = { ...initialState(), dashboard: { ...initialDashboardState, stats: sampleStats } };
    const store = createStore(state, reducer, env);
    const captured: AppAction[] = [];
    const wrappedStore = { ...store, dispatch: (a: AppAction) => { captured.push(a); store.dispatch(a); } };
    render(() => <Dashboard store={wrappedStore} />);
    await vi.waitUntil(() => screen.queryByText("w_zzzdead") != null);
    fireEvent.click(screen.getByText("w_zzzdead"));
    expect(captured).toContainEqual({
      tag: "objects",
      action: { tag: "select", name: "w_zzzdead" },
    });
  });

  it("hides schema tiles and shows a banner when ddl is not loaded", () => {
    const noDdlStats = { ...sampleStats, ddl_loaded: false };
    renderWithStore(Dashboard, {
      dashboard: { ...initialDashboardState, stats: noDdlStats },
    });
    expect(screen.queryByText("Unenforced FKs")).toBeNull();
    expect(screen.queryByText("Dead Columns")).toBeNull();
    expect(screen.getByText(/No DDL schema loaded/)).toBeDefined();
  });
});
