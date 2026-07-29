// tests/explore/BrowserSearchResults.test.tsx — Tests for the ported
// cross-entity search results body (Plan 211 Phase B).

import { describe, it, expect } from "vitest";
import { render, screen, fireEvent } from "@solidjs/testing-library";
import { createTestStore } from "../helpers.js";
import { BrowserSearchResults } from "../../app/src/views/features/explore/BrowserSearchResults.js";
import type { SearchResponse } from "@pb/platform";

describe("BrowserSearchResults component", () => {
  it("shows 'No results found' when results are empty", () => {
    const { store } = createTestStore();
    const data: SearchResponse = { objects: [], procedures: [], datawindows: [], tables: [] };
    render(() => <BrowserSearchResults store={store} data={data} />);
    expect(screen.getByText("No results found")).toBeDefined();
  });

  it("renders object results section", () => {
    const { store } = createTestStore();
    const data: SearchResponse = {
      objects: [{ name: "w_main", kind: "powerscript", category: "window", file: "f.pbl", ancestor: null }],
      procedures: [],
      datawindows: [],
      tables: [],
    };
    render(() => <BrowserSearchResults store={store} data={data} />);
    expect(screen.getByText("Objects (1)")).toBeDefined();
    expect(screen.getByText("w_main")).toBeDefined();
  });

  it("renders procedure results section", () => {
    const { store } = createTestStore();
    const data: SearchResponse = {
      objects: [],
      procedures: [{ object: "w_main", name: "of_click", proc_type: "function", modifiers: "public", start_line: 10 }],
      datawindows: [],
      tables: [],
    };
    render(() => <BrowserSearchResults store={store} data={data} />);
    expect(screen.getByText("Procedures (1)")).toBeDefined();
    expect(screen.getByText("of_click")).toBeDefined();
  });

  it("clicking an object row dispatches objects/select", () => {
    const { store, captured } = createTestStore();
    const data: SearchResponse = {
      objects: [{ name: "w_main", kind: "powerscript", category: "window", file: "f.pbl", ancestor: null }],
      procedures: [],
      datawindows: [],
      tables: [],
    };
    render(() => <BrowserSearchResults store={store} data={data} />);
    fireEvent.click(screen.getByText("w_main"));
    const selectActions = captured.filter((a) => a.tag === "objects" && a.action.tag === "select");
    expect(selectActions.length).toBe(1);
    expect(selectActions[0]).toEqual({ tag: "objects", action: { tag: "select", name: "w_main" } });
  });
});
