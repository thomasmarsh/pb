// tests/objects/detail/ProceduresCard.test.tsx — Tests for ProceduresCard component.

import { describe, it, expect } from "vitest";
import { screen, fireEvent } from "@solidjs/testing-library";
import { render } from "@solidjs/testing-library";
import { ProceduresCard } from "../../../app/src/views/features/objects/detail/ProceduresCard.js";
import { createTestStore } from "../../helpers.js";

const sampleProcs = [
  { name: "of_init",  proc_type: "function",   params: "(n)", return_type: "void", modifiers: "public", cyclomatic: 3,    start_line: 10, end_line: 20 },
  { name: "of_close", proc_type: "subroutine",  params: "",   return_type: null,   modifiers: null,     cyclomatic: null, start_line: 25, end_line: 30 },
  { name: "ue_click", proc_type: "event",        params: "",   return_type: null,   modifiers: null,     cyclomatic: 1,    start_line: 35, end_line: 40 },
];

describe("ProceduresCard", () => {
  it("renders procedure names", () => {
    const { store } = createTestStore();
    render(() => (
      <ProceduresCard store={store} objectName="w_main" procedures={sampleProcs} />
    ));
    expect(screen.getByText("of_init")).toBeDefined();
    expect(screen.getByText("of_close")).toBeDefined();
    expect(screen.getByText("ue_click")).toBeDefined();
  });

  it("shows total procedure count in header", () => {
    const { store } = createTestStore();
    render(() => (
      <ProceduresCard store={store} objectName="w_main" procedures={sampleProcs} />
    ));
    expect(screen.getByText("Procedures (3)")).toBeDefined();
  });

  it("renders kind group headers with counts", () => {
    const { store } = createTestStore();
    render(() => (
      <ProceduresCard store={store} objectName="w_main" procedures={sampleProcs} />
    ));
    expect(screen.getByText("Functions (1)")).toBeDefined();
    expect(screen.getByText("Events (1)")).toBeDefined();
    expect(screen.getByText("Subroutines (1)")).toBeDefined();
  });

  it("hides empty groups", () => {
    const { store } = createTestStore();
    const onlyFunctions = [sampleProcs[0]!];
    render(() => (
      <ProceduresCard store={store} objectName="w_main" procedures={onlyFunctions} />
    ));
    expect(screen.getByText("Functions (1)")).toBeDefined();
    expect(screen.queryByText(/Subroutines/)).toBeNull();
    expect(screen.queryByText(/Events/)).toBeNull();
  });

  it("dispatches proc-select on row click", () => {
    const { store, captured } = createTestStore();
    render(() => (
      <ProceduresCard store={store} objectName="w_main" procedures={sampleProcs} />
    ));
    fireEvent.click(screen.getByText("of_init"));
    const actions = captured.filter(a => a.tag === "objects" && a.action.tag === "proc-select");
    expect(actions.length).toBe(1);
    expect(actions[0]).toEqual({ tag: "objects", action: { tag: "proc-select", objectName: "w_main", procName: "of_init" } });
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

  it("shows owner prefix for control-level events", () => {
    const { store } = createTestStore();
    const procs = [
      { name: "open",    proc_type: "event", owner: "w_foo",      params: null, return_type: null, modifiers: null, cyclomatic: null, start_line: 1,  end_line: 5  },
      { name: "clicked", proc_type: "event", owner: "cb_cancel",  params: null, return_type: null, modifiers: null, cyclomatic: null, start_line: 10, end_line: 15 },
    ];
    render(() => (
      <ProceduresCard store={store} objectName="w_foo" procedures={procs} />
    ));
    expect(screen.getByText("open")).toBeDefined();
    expect(screen.getByText("cb_cancel · clicked")).toBeDefined();
  });

  it("shows bare name when owner equals objectName", () => {
    const { store } = createTestStore();
    const procs = [
      { name: "open", proc_type: "event", owner: "w_foo", params: null, return_type: null, modifiers: null, cyclomatic: null, start_line: 1, end_line: 5 },
    ];
    render(() => (
      <ProceduresCard store={store} objectName="w_foo" procedures={procs} />
    ));
    expect(screen.getByText("open")).toBeDefined();
    expect(screen.queryByText(/w_foo · open/)).toBeNull();
  });

  it("shows bare name when owner is null", () => {
    const { store } = createTestStore();
    const procs = [
      { name: "ue_orphan", proc_type: "event", owner: null, params: null, return_type: null, modifiers: null, cyclomatic: null, start_line: 1, end_line: 5 },
    ];
    render(() => (
      <ProceduresCard store={store} objectName="w_foo" procedures={procs} />
    ));
    expect(screen.getByText("ue_orphan")).toBeDefined();
  });
});
