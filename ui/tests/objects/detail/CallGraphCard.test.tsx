// tests/objects/detail/CallGraphCard.test.tsx — Tests for CallGraphCard component.

import { describe, it, expect } from "vitest";
import { screen, fireEvent } from "@solidjs/testing-library";
import { render } from "@solidjs/testing-library";
import { CallGraphCard } from "../../../src/features/objects/detail/CallGraphCard.js";
import { createTestStore } from "../../helpers.js";

describe("CallGraphCard", () => {
  it("renders callers and callees", () => {
    const { store } = createTestStore();
    render(() => (
      <CallGraphCard store={store} callers={["w_base", "w_login"]} callees={["of_util"]} />
    ));
    expect(screen.getByText("CALLERS (2)")).toBeDefined();
    expect(screen.getByText("CALLEES (1)")).toBeDefined();
    expect(screen.getByText("w_base")).toBeDefined();
    expect(screen.getByText("of_util")).toBeDefined();
  });

  it("dispatches select on caller click", () => {
    const { store, captured } = createTestStore();
    render(() => (
      <CallGraphCard store={store} callers={["w_base"]} callees={[]} />
    ));
    fireEvent.click(screen.getByText("w_base"));
    const actions = captured.filter(a => a.tag === "objects" && a.action.type === "select");
    expect(actions.length).toBe(1);
  });
});
