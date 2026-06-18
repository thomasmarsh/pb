// tests/features/DWDetail.test.tsx — Tests for DWDetail FaceToggle structure.

import { describe, it, expect } from "vitest";
import { fireEvent, render, waitFor } from "@solidjs/testing-library";
import { DWDetail } from "../../src/features/datawindows/DataWindows.js";
import { createTestStore } from "../helpers.js";
import { initialDatawindowsState } from "../../src/features/datawindows/reducer.js";
import type { DwDetailResponse } from "../../src/types/api.js";

function makeDw(overrides: Partial<DwDetailResponse> = {}): DwDetailResponse {
  return {
    name: "dw_orders",
    file: "w_order.srd",
    controls: [
      { control_name: "col_id", control_type: "column", band: "detail", x: 10, y: 20, width: 80, height: 24, expression: null, tab_seq: null, source_line: null },
    ],
    retrieve_tables: ["orders", "customers"],
    retrieve_columns: [{ column_fqn: "orders.id", table_name: "orders", column_name: "id" }],
    retrieve_where: [{ idx: 1, exp1: "orders.id", op: "=", exp2: ":arg_id", logic: "" }],
    arguments: [{ arg_name: "arg_id", arg_type: "long" }],
    source: "select 1 from orders",
    ...overrides,
  };
}

function renderDWDetail(
  dwDetail: DwDetailResponse | { error: string } | null,
  dwFace: "source" | "analysis" = "source",
) {
  const { store } = createTestStore({
    datawindows: { ...initialDatawindowsState, dwDetail, dwFace },
  });
  return render(() => <DWDetail store={store} />);
}

function cardHeaders(): string[] {
  return [...document.querySelectorAll(".card-header h3")].map((h) => h.textContent ?? "");
}

function toggleBtns(): Element[] {
  return [...document.querySelectorAll(".face-toggle-btn")];
}

describe("DWDetail FaceToggle", () => {
  it("renders Source and Analysis toggle buttons", () => {
    renderDWDetail(makeDw());
    const labels = toggleBtns().map((b) => b.textContent);
    expect(labels).toContain("Source");
    expect(labels).toContain("Analysis");
  });

  it("Source button is active by default", () => {
    renderDWDetail(makeDw());
    const sourceBtn = toggleBtns().find((b) => b.textContent === "Source");
    expect(sourceBtn?.classList.contains("active")).toBe(true);
  });

  it("source face shows Controls card when controls are present", () => {
    renderDWDetail(makeDw());
    expect(cardHeaders().some((h) => h.startsWith("Controls"))).toBe(true);
  });

  it("source face hides Controls card when no controls", () => {
    renderDWDetail(makeDw({ controls: [] }));
    expect(cardHeaders().some((h) => h.startsWith("Controls"))).toBe(false);
  });

  it("source face shows Source code card", () => {
    renderDWDetail(makeDw());
    expect(cardHeaders()).toContain("Source");
  });

  it("analysis face shows Tables Accessed card with table names", () => {
    renderDWDetail(makeDw(), "analysis");
    expect(cardHeaders()).toContain("Tables Accessed (2)");
    const names = [...document.querySelectorAll(".entity-card-name")].map((e) => e.textContent);
    expect(names).toContain("orders");
    expect(names).toContain("customers");
  });

  it("analysis face shows Retrieve Definition with args", () => {
    renderDWDetail(makeDw(), "analysis");
    expect(cardHeaders()).toContain("Retrieve Definition");
    expect(document.body.textContent).toContain("arg_id");
  });

  it("analysis face renders PhaseGate inline section", () => {
    renderDWDetail(makeDw(), "analysis");
    expect(document.querySelector(".phase-gate-inline")).not.toBeNull();
  });

  it("clicking Analysis button activates analysis face", async () => {
    renderDWDetail(makeDw());
    const analysisBtn = toggleBtns().find((b) => b.textContent === "Analysis")!;
    fireEvent.click(analysisBtn);
    await waitFor(() => expect(analysisBtn.classList.contains("active")).toBe(true));
  });
});
