// tests/objects/detail/ProceduresCard.test.tsx — Tests for ProceduresCard component.

import { describe, it, expect } from "vitest";
import { screen, fireEvent } from "@solidjs/testing-library";
import { render } from "@solidjs/testing-library";
import { ProceduresCard } from "../../../src/features/objects/detail/ProceduresCard.js";
import { createTestStore } from "../../helpers.js";

const sampleProcs = [
  { name: "of_init", proc_type: "function", params: "(n)", return_type: "void", modifiers: "public", cyclomatic: 3, start_line: 10, end_line: 20 },
  { name: "of_close", proc_type: "subroutine", params: "", return_type: null, modifiers: null, cyclomatic: null, start_line: 25, end_line: 30 },
];

describe("ProceduresCard", () => {
  it("renders procedure names", () => {
    const { store } = createTestStore();
    render(() => (
      <ProceduresCard store={store} objectName="w_main" procedures={sampleProcs} />
    ));
    expect(screen.getByText("of_init")).toBeDefined();
    expect(screen.getByText("of_close")).toBeDefined();
  });

  it("shows procedure count in header", () => {
    const { store } = createTestStore();
    render(() => (
      <ProceduresCard store={store} objectName="w_main" procedures={sampleProcs} />
    ));
    expect(screen.getByText("Procedures (2)")).toBeDefined();
  });

  it("renders proc_type badges", () => {
    const { store } = createTestStore();
    render(() => (
      <ProceduresCard store={store} objectName="w_main" procedures={sampleProcs} />
    ));
    expect(screen.getByText("function")).toBeDefined();
    expect(screen.getByText("subroutine")).toBeDefined();
  });

  it("dispatches proc-select on row click", () => {
    const { store, captured } = createTestStore();
    render(() => (
      <ProceduresCard store={store} objectName="w_main" procedures={sampleProcs} />
    ));
    fireEvent.click(screen.getByText("of_init"));
    const actions = captured.filter(a => a.tag === "objects" && a.action.type === "proc-select");
    expect(actions.length).toBe(1);
    expect(actions[0]).toEqual({ tag: "objects", action: { type: "proc-select", objectName: "w_main", procName: "of_init" } });
  });

  it("shows CC badge when cyclomatic is present", () => {
    const { store } = createTestStore();
    render(() => (
      <ProceduresCard store={store} objectName="w_main" procedures={sampleProcs} />
    ));
    expect(screen.getByText("3")).toBeDefined();
  });

  it("shows line range when available", () => {
    const { store } = createTestStore();
    render(() => (
      <ProceduresCard store={store} objectName="w_main" procedures={sampleProcs} />
    ));
    expect(screen.getByText("10–20")).toBeDefined();
    expect(screen.getByText("25–30")).toBeDefined();
  });
});
