// tests/objects/ProcedureDetail.test.tsx — Tests for ProcedureDetail FaceToggle structure.

import { describe, it, expect } from "vitest";
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

function renderProcDetail(
  proc: ProcedureDetailResponse | { error: string } | null = baseProc,
  procFace: "source" | "analysis" = "source",
) {
  const route = { view: "procedureDetail" as const, name: "w_main", proc: "f_process" };
  const { store, captured } = createTestStore({
    objects: { ...initialObjectsState, procedureDetail: proc, procFace },
    nav: { route } as any,
  });
  render(() => <ProcedureDetail store={store} />);
  return { store, captured };
}

describe("ProcedureDetail face/toggle", () => {
  it("renders Source face active by default", () => {
    renderProcDetail();
    const active = document.querySelector(".face-toggle-btn.active");
    expect(active?.textContent).toBe("Source");
  });

  it("renders Analysis face when procFace is analysis", () => {
    renderProcDetail(baseProc, "analysis");
    const active = document.querySelector(".face-toggle-btn.active");
    expect(active?.textContent).toBe("Analysis");
  });

  it("dispatches set-proc-face when Analysis button is clicked", () => {
    const { captured } = renderProcDetail();
    const analysisBtn = [...document.querySelectorAll(".face-toggle-btn")]
      .find((b) => b.textContent === "Analysis")!;
    fireEvent.click(analysisBtn);
    const faceActions = captured.filter(
      (a) => a.tag === "objects" && a.action.tag === "set-proc-face",
    );
    expect(faceActions.length).toBeGreaterThanOrEqual(1);
    expect((faceActions[0] as any).action.face).toBe("analysis");
  });

  it("Analysis face: shows callers as EntityCards", () => {
    renderProcDetail(baseProc, "analysis");
    const cards = document.querySelectorAll(".entity-card");
    const names = [...cards].map((c) => c.textContent ?? "");
    expect(names.some((n) => n.includes("w_login"))).toBe(true);
  });

  it("Analysis face: shows 'No callers' note when callers is empty", () => {
    renderProcDetail({ ...baseProc, callers: [] }, "analysis");
    expect(document.body.textContent).toMatch(/no callers/i);
  });

  it("Analysis face: shows callees as EntityCards", () => {
    renderProcDetail({ ...baseProc, callees: ["n_cst_util.of_validate"] }, "analysis");
    const cards = document.querySelectorAll(".entity-card");
    const names = [...cards].map((c) => c.textContent ?? "");
    expect(names.some((n) => n.includes("n_cst_util.of_validate"))).toBe(true);
  });

  it("Analysis face: shows PhaseGate rows for CFG, taint, formal", () => {
    renderProcDetail(baseProc, "analysis");
    const rows = document.querySelectorAll(".phase-gate-inline");
    expect(rows.length).toBeGreaterThanOrEqual(3);
  });

  it("Source face: does not show PhaseGate rows", () => {
    renderProcDetail(baseProc, "source");
    const rows = document.querySelectorAll(".phase-gate-inline");
    expect(rows.length).toBe(0);
  });

  it("Source face: renders proc metadata (name, type, params)", () => {
    renderProcDetail();
    expect(document.body.textContent).toContain("f_process");
    expect(document.body.textContent).toContain("long al_id");
  });

  it("renders error state when procedureDetail has error", () => {
    renderProcDetail({ error: "Procedure not found" });
    expect(document.body.textContent).toContain("Procedure not found");
  });

  it("renders Loading when procedureDetail is null", () => {
    renderProcDetail(null);
    expect(document.body.textContent).toMatch(/loading/i);
  });
});
