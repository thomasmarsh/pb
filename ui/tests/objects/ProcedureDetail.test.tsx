// tests/objects/ProcedureDetail.test.tsx — Tests for source-first ProcedureDetail.

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { fireEvent, render } from "@solidjs/testing-library";
import { ProcedureDetail } from "../../src/features/objects/ProcedureDetail.js";
import { createTestStore } from "../helpers.js";
import { initialObjectsState } from "../../src/features/objects/reducer.js";
import type { ProcedureDetailResponse } from "../../src/types/api.js";

const baseProc: ProcedureDetailResponse = {
  object: "w_main",
  proc_type: "function",
  name: "f_process",
  modifiers: "public",
  params: "long al_id",
  return_type: "boolean",
  start_line: 10,
  end_line: 30,
  cyclomatic: 3,
  source_original: "function boolean f_process(long al_id)\nreturn true\nend function",
  source_rendered: "function boolean f_process(long al_id)\nreturn true\nend function",
  callers: [
    { object: "w_login", proc: "cb_ok_clicked" },
    { object: "w_admin", proc: "f_init" },
  ],
  callees: ["n_cst_util.of_validate"],
  sql_statements: [],
};

function renderProcDetail(proc: ProcedureDetailResponse | { error: string } | null = baseProc) {
  const route = { view: "procedureDetail" as const, name: "w_main", proc: "f_process" };
  const { store, captured } = createTestStore({
    objects: { ...initialObjectsState, procedureDetail: proc },
    nav: { route } as any,
  });
  render(() => <ProcedureDetail store={store} />);
  return { store, captured };
}

describe("ProcedureDetail source-first", () => {
  it("does not render a FaceToggle", () => {
    renderProcDetail();
    expect(document.querySelector(".face-toggle")).toBeNull();
  });

  it("shows source code directly without a tab bar", () => {
    renderProcDetail();
    expect(document.querySelector(".tab-bar")).toBeNull();
    expect(document.body.textContent).toContain("f_process");
  });

  it("renders AnalysisSummaryBar", () => {
    renderProcDetail();
    expect(document.querySelector(".analysis-summary-bar")).not.toBeNull();
  });

  it("shows Callers pill with correct count", () => {
    renderProcDetail();
    const bar = document.querySelector(".analysis-summary-bar");
    expect(bar?.textContent).toContain("Callers (2)");
  });

  it("shows Callees pill with correct count", () => {
    renderProcDetail();
    const bar = document.querySelector(".analysis-summary-bar");
    expect(bar?.textContent).toContain("Callees (1)");
  });

  it("shows CC pill when cyclomatic is set", () => {
    renderProcDetail();
    const bar = document.querySelector(".analysis-summary-bar");
    expect(bar?.textContent).toContain("CC: 3");
  });

  it("does not show SQL pill when sql_statements is empty", () => {
    renderProcDetail();
    const bar = document.querySelector(".analysis-summary-bar");
    expect(bar?.textContent).not.toContain("SQL");
  });

  it("shows SQL pill when sql_statements is non-empty", () => {
    renderProcDetail({
      ...baseProc,
      sql_statements: [{ line: 1, operation: "SELECT", raw_sql: "SELECT 1", formatted_sql: "SELECT 1", parse_ok: true, tables: [], columns: null, has_into: false, has_cursor: false }],
    });
    const bar = document.querySelector(".analysis-summary-bar");
    expect(bar?.textContent).toContain("SQL (1)");
  });

  it("callers panel is hidden initially", () => {
    renderProcDetail();
    const cards = document.querySelectorAll(".entity-card");
    expect(cards.length).toBe(0);
  });

  it("clicking Callers pill opens callers panel with entity cards", () => {
    renderProcDetail();
    const pills = [...document.querySelectorAll(".analysis-summary-bar button")];
    const callersPill = pills.find((b) => b.textContent?.includes("Callers"))!;
    fireEvent.click(callersPill);
    const cards = document.querySelectorAll(".entity-card");
    const names = [...cards].map((c) => c.textContent ?? "");
    expect(names.some((n) => n.includes("w_login"))).toBe(true);
    expect(names.some((n) => n.includes("cb_ok_clicked"))).toBe(true);
  });

  it("clicking Callers pill again closes the panel", () => {
    renderProcDetail();
    const pills = () => [...document.querySelectorAll(".analysis-summary-bar button")];
    const callersPill = () => pills().find((b) => b.textContent?.includes("Callers"))!;
    fireEvent.click(callersPill());
    expect(document.querySelectorAll(".entity-card").length).toBeGreaterThan(0);
    fireEvent.click(callersPill());
    expect(document.querySelectorAll(".entity-card").length).toBe(0);
  });

  it("multiple panels can be open simultaneously", () => {
    renderProcDetail();
    const pills = [...document.querySelectorAll(".analysis-summary-bar button")];
    const callersPill = pills.find((b) => b.textContent?.includes("Callers"))!;
    const calleesPill = pills.find((b) => b.textContent?.includes("Callees"))!;
    fireEvent.click(callersPill);
    fireEvent.click(calleesPill);
    // Both panels should now show entity cards
    const cards = document.querySelectorAll(".entity-card");
    expect(cards.length).toBeGreaterThanOrEqual(2);
  });

  it("shows 'No callers' note when callers is empty and panel is open", () => {
    renderProcDetail({ ...baseProc, callers: [] });
    const pills = [...document.querySelectorAll(".analysis-summary-bar button")];
    const callersPill = pills.find((b) => b.textContent?.includes("Callers"))!;
    fireEvent.click(callersPill);
    expect(document.body.textContent).toMatch(/no callers/i);
  });

  it("callee panel shows callee entity cards when open", () => {
    renderProcDetail({ ...baseProc, callees: ["n_cst_util.of_validate"] });
    const pills = [...document.querySelectorAll(".analysis-summary-bar button")];
    const calleesPill = pills.find((b) => b.textContent?.includes("Callees"))!;
    fireEvent.click(calleesPill);
    const cards = document.querySelectorAll(".entity-card");
    const names = [...cards].map((c) => c.textContent ?? "");
    expect(names.some((n) => n.includes("n_cst_util.of_validate"))).toBe(true);
  });

  it("renders proc metadata in header (name, params, return type)", () => {
    renderProcDetail();
    expect(document.body.textContent).toContain("f_process");
    expect(document.body.textContent).toContain("long al_id");
    expect(document.body.textContent).toContain("boolean");
  });

  it("renders error state when procedureDetail has error", () => {
    renderProcDetail({ error: "Procedure not found" });
    expect(document.body.textContent).toContain("Procedure not found");
  });

  it("renders Loading when procedureDetail is null", () => {
    renderProcDetail(null);
    expect(document.body.textContent).toMatch(/loading/i);
  });

  describe("CFG panel", () => {
    beforeEach(() => {
      vi.stubGlobal("fetch", () => new Promise(() => {}));
    });
    afterEach(() => {
      vi.unstubAllGlobals();
    });

    it("shows CFG pill in summary bar", () => {
      renderProcDetail();
      const bar = document.querySelector(".analysis-summary-bar");
      expect(bar?.textContent).toContain("CFG");
    });

    it("clicking CFG pill opens ContextualPanel with 'Control Flow Graph' title", () => {
      renderProcDetail();
      const pills = [...document.querySelectorAll(".analysis-summary-bar button")];
      const cfgPill = pills.find((b) => b.textContent?.includes("CFG"))!;
      expect(cfgPill).toBeDefined();
      fireEvent.click(cfgPill);
      expect(document.body.textContent).toContain("Control Flow Graph");
    });

    it("clicking CFG pill again closes the panel", () => {
      renderProcDetail();
      const pill = () =>
        [...document.querySelectorAll(".analysis-summary-bar button")].find(
          (b) => b.textContent?.includes("CFG"),
        )!;
      fireEvent.click(pill());
      expect(document.body.textContent).toContain("Control Flow Graph");
      fireEvent.click(pill());
      expect(document.body.textContent).not.toContain("Control Flow Graph");
    });
  });
});
