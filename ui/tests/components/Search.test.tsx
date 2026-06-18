// tests/components/Search.test.tsx — Tests for Search component.

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { screen, fireEvent } from "@solidjs/testing-library";
import { renderWithStore } from "../helpers.js";
import { Search } from "../../src/features/search/Search.js";

describe("Search component", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("renders search input with placeholder", () => {
    renderWithStore(Search);
    expect(screen.getByPlaceholderText("Search everything...")).toBeDefined();
  });

  it("typing 2+ chars dispatches debounced search", async () => {
    const { captured } = renderWithStore(Search);
    const input = screen.getByPlaceholderText("Search everything...");
    fireEvent.input(input, { target: { value: "fn" } });
    await vi.advanceTimersByTimeAsync(350);
    const searchActions = captured.filter(
      (a) => a.tag === "search" && a.action.type === "term",
    );
    expect(searchActions.length).toBe(1);
    expect(searchActions[0]).toEqual({ tag: "search", action: { type: "term", term: "fn" } });
  });

  it("Enter key dispatches immediately for 1+ char", () => {
    const { captured } = renderWithStore(Search);
    const input = screen.getByPlaceholderText("Search everything...");
    fireEvent.input(input, { target: { value: "f" } });
    fireEvent.keyDown(input, { key: "Enter" });
    const searchActions = captured.filter(
      (a) => a.tag === "search" && a.action.type === "term",
    );
    expect(searchActions.length).toBe(1);
    expect(searchActions[0]).toEqual({ tag: "search", action: { type: "term", term: "f" } });
  });

  it("dispatches debounced search only for 2+ char terms", async () => {
    const { captured } = renderWithStore(Search);
    const input = screen.getByPlaceholderText("Search everything...");
    fireEvent.input(input, { target: { value: "a" } });
    await vi.advanceTimersByTimeAsync(400);
    const searchActions = captured.filter(
      (a) => a.tag === "search" && a.action.type === "term",
    );
    expect(searchActions.length).toBe(0);
  });

  it("shows 'No results found' when results are empty", () => {
    renderWithStore(Search, {
      search: { term: "xyz", loading: false, results: { objects: [], procedures: [], datawindows: [], tables: [] }, recentSearches: [], overlayOpen: false, overlayTerm: "", overlayResults: null, overlayLoading: false },
    });
    expect(screen.getByText("No results found")).toBeDefined();
  });

  it("renders object results section", () => {
    renderWithStore(Search, {
      search: {
        term: "test", loading: false,
        results: {
          objects: [{ name: "w_main", kind: "powerscript", file: "f.pbl", ancestor: null }],
          procedures: [],
          datawindows: [],
          tables: [],
        },
        recentSearches: [], overlayOpen: false, overlayTerm: "", overlayResults: null, overlayLoading: false,
      },
    });
    expect(screen.getByText("Objects (1)")).toBeDefined();
    expect(screen.getByText("w_main")).toBeDefined();
  });

  it("renders procedure results section", () => {
    renderWithStore(Search, {
      search: {
        term: "test", loading: false,
        results: {
          objects: [],
          procedures: [{ object: "w_main", name: "of_click", proc_type: "function", modifiers: "public", start_line: 10 }],
          datawindows: [],
          tables: [],
        },
        recentSearches: [], overlayOpen: false, overlayTerm: "", overlayResults: null, overlayLoading: false,
      },
    });
    expect(screen.getByText("Procedures (1)")).toBeDefined();
    expect(screen.getByText("of_click")).toBeDefined();
  });

  it("clicking an object row dispatches objects/select", () => {
    const { captured } = renderWithStore(Search, {
      search: {
        term: "test", loading: false,
        results: {
          objects: [{ name: "w_main", kind: "powerscript", file: "f.pbl", ancestor: null }],
          procedures: [],
          datawindows: [],
          tables: [],
        },
        recentSearches: [], overlayOpen: false, overlayTerm: "", overlayResults: null, overlayLoading: false,
      },
    });
    fireEvent.click(screen.getByText("w_main"));
    const selectActions = captured.filter(
      (a) => a.tag === "objects" && a.action.type === "select",
    );
    expect(selectActions.length).toBe(1);
    expect(selectActions[0]).toEqual({ tag: "objects", action: { type: "select", name: "w_main" } });
  });
});
