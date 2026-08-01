// tests/features/Capabilities.test.tsx — Corpus-wide capability catalog view
// (Plan 225 Phase 2). Each capability row expands to its procedure list,
// lazily fetched via the second /api/analysis/capabilities/{capability}
// route and cached in AnalysisState.capabilityProcedures — same
// expandable-row shape as DecompositionCandidatesTable, but keyed by
// capability string instead of row index.

import { describe, it, expect } from "vitest";
import { fireEvent, render } from "@solidjs/testing-library";
import { Capabilities } from "../../app/src/views/features/analysis/Capabilities.js";
import { createTestStore } from "../helpers.js";
import { initialAnalysisState } from "@pb/platform";
import type { CapabilityCatalogItem, CapabilityProcedureRef } from "@pb/platform";

const capabilities: CapabilityCatalogItem[] = [
  { capability: "DB", proc_count: 2 },
  { capability: "UI", proc_count: 1 },
];

function rows(): HTMLElement[] {
  return [...document.querySelectorAll(".capability-row")] as HTMLElement[];
}

function evidenceRows(): HTMLElement[] {
  return [...document.querySelectorAll(".capability-evidence-row")] as HTMLElement[];
}

describe("Capabilities", () => {
  it("renders one row per capability with its procedure count", () => {
    const { store } = createTestStore({
      analysis: { ...initialAnalysisState, capabilities, capabilitiesLoaded: true },
    });
    render(() => <Capabilities store={store} />);
    expect(rows()).toHaveLength(2);
    expect(rows()[0]!.textContent).toContain("DB");
    expect(rows()[0]!.textContent).toContain("2");
    expect(rows()[1]!.textContent).toContain("UI");
    expect(rows()[1]!.textContent).toContain("1");
  });

  it("shows a loading state before the catalog has loaded", () => {
    const { store } = createTestStore({
      analysis: { ...initialAnalysisState },
    });
    render(() => <Capabilities store={store} />);
    expect(rows()).toHaveLength(0);
    expect(document.body.textContent).toContain("Loading");
  });

  it("clicking an unexpanded row dispatches load-capability-procedures for that capability", () => {
    const { store, captured } = createTestStore({
      analysis: { ...initialAnalysisState, capabilities, capabilitiesLoaded: true },
    });
    render(() => <Capabilities store={store} />);
    fireEvent.click(rows()[0]!);
    expect(captured).toContainEqual({
      tag: "analysis",
      action: { tag: "load-capability-procedures", capability: "DB" },
    });
  });

  it("expanding a row whose procedures are already cached renders them without re-dispatching", () => {
    const procs: CapabilityProcedureRef[] = [
      { object: "w_obj", proc_name: "proc_a" },
      { object: "w_obj", proc_name: "proc_c" },
    ];
    const { store, captured } = createTestStore({
      analysis: {
        ...initialAnalysisState,
        capabilities,
        capabilitiesLoaded: true,
        capabilityProcedures: { DB: procs },
      },
    });
    render(() => <Capabilities store={store} />);
    fireEvent.click(rows()[0]!);
    expect(evidenceRows()).toHaveLength(1);
    expect(evidenceRows()[0]!.textContent).toContain("proc_a");
    expect(evidenceRows()[0]!.textContent).toContain("proc_c");
    expect(captured.some((a) => a.tag === "analysis" && a.action.tag === "load-capability-procedures")).toBe(false);
  });

  it("clicking a listed procedure dispatches proc-select navigation", () => {
    const procs: CapabilityProcedureRef[] = [{ object: "w_obj", proc_name: "proc_a" }];
    const { store, captured } = createTestStore({
      analysis: {
        ...initialAnalysisState,
        capabilities,
        capabilitiesLoaded: true,
        capabilityProcedures: { DB: procs },
      },
    });
    render(() => <Capabilities store={store} />);
    fireEvent.click(rows()[0]!);
    const procRow = document.querySelector(".capability-proc-list li");
    expect(procRow).not.toBeNull();
    fireEvent.click(procRow!);
    expect(captured).toContainEqual({
      tag: "objects",
      action: { tag: "proc-select", objectName: "w_obj", procName: "proc_a" },
    });
  });

  it("collapses an expanded row when clicked again", () => {
    const procs: CapabilityProcedureRef[] = [{ object: "w_obj", proc_name: "proc_a" }];
    const { store } = createTestStore({
      analysis: {
        ...initialAnalysisState,
        capabilities,
        capabilitiesLoaded: true,
        capabilityProcedures: { DB: procs },
      },
    });
    render(() => <Capabilities store={store} />);
    fireEvent.click(rows()[0]!);
    expect(evidenceRows()).toHaveLength(1);
    fireEvent.click(rows()[0]!);
    expect(evidenceRows()).toHaveLength(0);
  });
});
