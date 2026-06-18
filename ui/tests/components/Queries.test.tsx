// tests/components/Queries.test.tsx — Tests for Queries component.

import { describe, it, expect } from "vitest";
import { screen, fireEvent } from "@solidjs/testing-library";
import { renderWithStore } from "../helpers.js";
import { Queries } from "../../src/features/queries/Queries.js";
import { initialQueriesState } from "../../src/features/queries/reducer.js";

const sampleQueries = [
  {
    name: "top_complex",
    description: "Most complex procedures",
    params: [{ name: "n", type: "integer", default: "10" }],
    sql: "SELECT name FROM procedures ORDER BY cc DESC",
  },
];

describe("Queries component", () => {
  it("renders query list from store state", () => {
    renderWithStore(Queries, {
      queries: { ...initialQueriesState, items: sampleQueries },
    });
    expect(screen.getByText("top_complex")).toBeDefined();
    expect(screen.getByText("Most complex procedures")).toBeDefined();
  });

  it("Run button dispatches queries/run with bound params", () => {
    const { captured } = renderWithStore(Queries, {
      queries: { ...initialQueriesState, items: sampleQueries },
    });
    fireEvent.click(screen.getByText("Run"));
    const runActions = captured.filter(
      (a) => a.tag === "queries" && a.action.tag === "run",
    );
    expect(runActions.length).toBe(1);
    expect(runActions[0]).toEqual({
      tag: "queries",
      action: { tag: "run", name: "top_complex", params: { n: "10" } },
    });
  });

  it("SQL toggle button shows/hides SQL block", () => {
    const { container } = renderWithStore(Queries, {
      queries: { ...initialQueriesState, items: sampleQueries },
    });
    expect(screen.getByText("SQL")).toBeDefined();
    fireEvent.click(screen.getByText("SQL"));
    expect(screen.getByText("Hide SQL")).toBeDefined();
    const pre = container.querySelector("pre.sql-code");
    expect(pre).not.toBeNull();
    expect(pre!.textContent).toContain("SELECT");
    expect(pre!.textContent).toContain("FROM");
    expect(pre!.textContent).toContain("procedures");
  });

  it("renders results table when results exist", () => {
    renderWithStore(Queries, {
      queries: {
        ...initialQueriesState,
        items: [],
        results: {
          columns: [
            { name: "name", entity_type: null },
            { name: "cc",   entity_type: null },
          ],
          rows: [{ name: "of_calc", cc: 15 }, { name: "of_draw", cc: 8 }],
        },
        resultsName: "top_complex",
      },
    });
    expect(screen.getByText(/top_complex/)).toBeDefined();
    expect(screen.getByText("of_calc")).toBeDefined();
    expect(screen.getByText("of_draw")).toBeDefined();
  });

  it("renders error message when results contain error", () => {
    renderWithStore(Queries, {
      queries: {
        ...initialQueriesState,
        items: [],
        results: { error: "connection refused" },
        resultsName: "top_complex",
      },
    });
    expect(screen.getByText("connection refused")).toBeDefined();
  });

  it("renders query param inputs with default values", () => {
    renderWithStore(Queries, {
      queries: { ...initialQueriesState, items: sampleQueries },
    });
    const input = screen.getByPlaceholderText("n (10)");
    expect(input).toBeDefined();
  });
});
