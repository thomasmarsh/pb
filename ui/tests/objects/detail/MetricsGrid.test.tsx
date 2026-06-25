// tests/objects/detail/MetricsGrid.test.tsx — Tests for MetricsGrid component.

import { describe, it, expect } from "vitest";
import { screen } from "@solidjs/testing-library";
import { render } from "@solidjs/testing-library";
import { MetricsGrid } from "@pb/platform";

describe("MetricsGrid", () => {
  it("renders metric labels and values", () => {
    render(() => (
      <MetricsGrid metrics={{ in_degree: 5, out_degree: 3, max_cyclomatic: 8 }} />
    ));
    expect(screen.getByText("In Degree")).toBeDefined();
    expect(screen.getByText("5")).toBeDefined();
    expect(screen.getByText("Out Degree")).toBeDefined();
    expect(screen.getByText("3")).toBeDefined();
    expect(screen.getByText("Max CC")).toBeDefined();
    expect(screen.getByText("8")).toBeDefined();
  });

  it("shows dash for null metrics", () => {
    render(() => (
      <MetricsGrid metrics={{ in_degree: null, pagerank: null }} />
    ));
    const dashes = screen.getAllByText("–");
    expect(dashes.length).toBeGreaterThanOrEqual(2);
  });

  it("formats avg_cyclomatic to 1 decimal", () => {
    render(() => (
      <MetricsGrid metrics={{ avg_cyclomatic: 3.456 }} />
    ));
    expect(screen.getByText("3.5")).toBeDefined();
  });

  it("formats pagerank to 4 decimals", () => {
    render(() => (
      <MetricsGrid metrics={{ pagerank: 0.12345 }} />
    ));
    expect(screen.getByText("0.1235")).toBeDefined();
  });
});
