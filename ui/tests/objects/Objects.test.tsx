// tests/components/Objects.test.tsx — Tests for Objects list component.

import { describe, it, expect } from "vitest";
import { screen, fireEvent } from "@solidjs/testing-library";
import { renderWithStore } from "../helpers.js";
import { Objects } from "../../src/features/objects/Objects.js";
import { initialObjectsState } from "@pb/platform";

const sampleItems = [
  { name: "w_main", kind: "powerscript", file: "app.pbl", ancestor: "w_base" },
  { name: "d_emp", kind: "datawindow", file: "app.pbl", ancestor: null },
  { name: "p_util", kind: "project", file: "app.pbl", ancestor: null },
];

describe("Objects component", () => {
  it("renders search input with placeholder", () => {
    renderWithStore(Objects);
    expect(screen.getByPlaceholderText("Search objects…")).toBeDefined();
  });

  it("dispatches objects/search on input", () => {
    const { captured } = renderWithStore(Objects);
    const input = screen.getByPlaceholderText("Search objects…");
    fireEvent.input(input, { target: { value: "w_" } });
    const searchActions = captured.filter(
      (a) => a.tag === "objects" && a.action.tag === "search",
    );
    expect(searchActions.length).toBeGreaterThanOrEqual(1);
  });

  it("renders filter pills", () => {
    renderWithStore(Objects);
    expect(screen.getByText("All")).toBeDefined();
    expect(screen.getByText("powerscript")).toBeDefined();
    expect(screen.getByText("datawindow")).toBeDefined();
  });

  it("clicking filter pill dispatches filter-kind", () => {
    const { captured } = renderWithStore(Objects);
    fireEvent.click(screen.getByText("datawindow"));
    const filterActions = captured.filter(
      (a) => a.tag === "objects" && a.action.tag === "filter-kind",
    );
    expect(filterActions.length).toBeGreaterThanOrEqual(1);
  });

  it("renders object table when items exist", () => {
    renderWithStore(Objects, {
      objects: {
        ...initialObjectsState, items: sampleItems, total: 3,
      },
    });
    expect(screen.getByText("w_main")).toBeDefined();
    expect(screen.getByText("d_emp")).toBeDefined();
    expect(screen.getByText("p_util")).toBeDefined();
  });

  it("clicking object row dispatches select", () => {
    const { captured } = renderWithStore(Objects, {
      objects: {
        ...initialObjectsState, items: sampleItems, total: 3,
      },
    });
    fireEvent.click(screen.getByText("w_main"));
    const selectActions = captured.filter(
      (a) => a.tag === "objects" && a.action.tag === "select",
    );
    expect(selectActions.length).toBe(1);
    expect(selectActions[0]).toEqual({ tag: "objects", action: { tag: "select", name: "w_main" } });
  });

  it("clicking column header dispatches sort", () => {
    const { captured } = renderWithStore(Objects, {
      objects: {
        ...initialObjectsState, items: sampleItems, total: 3,
      },
    });
    fireEvent.click(screen.getByText(/^Kind/));
    const sortActions = captured.filter(
      (a) => a.tag === "objects" && a.action.tag === "sort",
    );
    expect(sortActions.length).toBeGreaterThanOrEqual(1);
  });

  it("shows loading when loading and no items", () => {
    renderWithStore(Objects, {
      objects: {
        ...initialObjectsState, q: "test", loading: true,
      },
    });
    expect(screen.getByText("Loading...")).toBeDefined();
  });
});
