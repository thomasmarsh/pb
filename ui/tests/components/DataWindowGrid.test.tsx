// tests/components/DataWindowGrid.test.ts — Tests for DataWindowGrid component.

import { describe, it, expect, vi } from "vitest";
import { render } from "@solidjs/testing-library";
import { DataWindowGrid } from "@pb/platform";

describe("DataWindowGrid", () => {
  it("renders column headers from data keys", () => {
    const { container } = render(() => (
      <DataWindowGrid data={[{ name: "Alice", age: 30 }]} />
    ));
    const ths = container.querySelectorAll("th");
    expect(ths.length).toBe(2);
    expect(ths[0]?.textContent).toBe("name");
    expect(ths[1]?.textContent).toBe("age");
  });

  it("renders rows with cell values", () => {
    const { container } = render(() => (
      <DataWindowGrid data={[{ name: "Alice" }, { name: "Bob" }]} />
    ));
    const cells = container.querySelectorAll("td");
    expect(cells.length).toBe(2);
    expect(cells[0]?.textContent).toBe("Alice");
    expect(cells[1]?.textContent).toBe("Bob");
  });

  it("renders 'No data' for empty data array", () => {
    const { container } = render(() => (
      <DataWindowGrid data={[]} />
    ));
    expect(container.textContent).toContain("No data");
  });

  it("calls onCellClick with row index, column, value", () => {
    const onClick = vi.fn();
    const { container } = render(() => (
      <DataWindowGrid
        data={[{ name: "Alice", age: 30 }]}
        onCellClick={onClick}
      />
    ));
    const cell = container.querySelector("td");
    cell?.click();
    expect(onClick).toHaveBeenCalledWith(0, "name", "Alice");
  });

  it("uses explicit columns when provided", () => {
    const { container } = render(() => (
      <DataWindowGrid data={[{ name: "Alice", age: 30 }]} columns={["name"]} />
    ));
    const ths = container.querySelectorAll("th");
    expect(ths.length).toBe(1);
    expect(ths[0]?.textContent).toBe("name");
  });
});
