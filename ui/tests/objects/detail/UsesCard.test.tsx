// tests/objects/detail/UsesCard.test.tsx — Tests for UsesCard component.

import { describe, it, expect } from "vitest";
import { screen, fireEvent, render } from "@solidjs/testing-library";
import { UsesCard } from "../../../app/src/views/features/objects/detail/UsesCard.js";
import { createTestStore } from "../../helpers.js";
import type { UseInfo } from "@pb/platform";

const sampleUses: UseInfo[] = [
  { kind: "window_open", target: "w_continue", target_category: "window", proc_name: "cb_ok", line: 42, control_name: null },
  { kind: "object_create", target: "m_popup", target_category: "menu", proc_name: "open", line: 10, control_name: null },
  { kind: "menu_binding", target: "m_main", target_category: "menu", proc_name: null, line: null, control_name: null },
  { kind: "dw_binding", target: "d_emp", target_category: "datawindow", proc_name: null, line: null, control_name: "dw_1" },
  { kind: "function_call", target: "fn_calc", target_category: "function", proc_name: "of_calc", line: 7, control_name: null },
];

describe("UsesCard", () => {
  it("renders every use target", () => {
    const { store } = createTestStore();
    render(() => <UsesCard store={store} uses={sampleUses} />);
    expect(screen.getByText("w_continue")).toBeDefined();
    expect(screen.getByText("m_popup")).toBeDefined();
    expect(screen.getByText("m_main")).toBeDefined();
    expect(screen.getByText("d_emp")).toBeDefined();
    expect(screen.getByText("fn_calc")).toBeDefined();
  });

  it("shows a per-kind context label with proc/line for call-shaped uses", () => {
    const { store } = createTestStore();
    render(() => <UsesCard store={store} uses={sampleUses} />);
    expect(screen.getByText("opens · cb_ok:42")).toBeDefined();
    expect(screen.getByText("creates · open:10")).toBeDefined();
    expect(screen.getByText("calls · of_calc:7")).toBeDefined();
  });

  it("shows a bare context label for uses with no proc/line", () => {
    const { store } = createTestStore();
    render(() => <UsesCard store={store} uses={sampleUses} />);
    expect(screen.getByText("menu")).toBeDefined();
  });

  it("shows the control name for a DW binding", () => {
    const { store } = createTestStore();
    render(() => <UsesCard store={store} uses={sampleUses} />);
    expect(screen.getByText("DataWindow binding (dw_1)")).toBeDefined();
  });

  it("shows empty text when there are no uses", () => {
    const { store } = createTestStore();
    render(() => <UsesCard store={store} uses={[]} />);
    expect(screen.getByText("No statically-resolvable uses found.")).toBeDefined();
  });

  it("dispatches objects/select for a non-datawindow target", () => {
    const { store, captured } = createTestStore();
    render(() => <UsesCard store={store} uses={sampleUses} />);
    fireEvent.click(screen.getByText("w_continue"));
    expect(captured).toContainEqual({ tag: "objects", action: { tag: "select", name: "w_continue" } });
  });

  it("dispatches datawindows/select for a datawindow target", () => {
    const { store, captured } = createTestStore();
    render(() => <UsesCard store={store} uses={sampleUses} />);
    fireEvent.click(screen.getByText("d_emp"));
    expect(captured).toContainEqual({ tag: "datawindows", action: { tag: "select", name: "d_emp" } });
  });
});
