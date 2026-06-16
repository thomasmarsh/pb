// tests/objects/detail/InheritanceCard.test.tsx — Tests for InheritanceCard component.

import { describe, it, expect } from "vitest";
import { screen, fireEvent } from "@solidjs/testing-library";
import { render } from "@solidjs/testing-library";
import { InheritanceCard } from "../../../src/features/objects/detail/InheritanceCard.js";
import { createTestStore } from "../../helpers.js";

describe("InheritanceCard", () => {
  it("renders ancestor chain", () => {
    const { store } = createTestStore();
    render(() => (
      <InheritanceCard store={store} name="w_main" ancestors={["w_base", "w_frame"]} />
    ));
    expect(screen.getByText("w_main")).toBeDefined();
    expect(screen.getByText("w_base")).toBeDefined();
    expect(screen.getByText("w_frame")).toBeDefined();
  });

  it("dispatches select on ancestor click", () => {
    const { store, captured } = createTestStore();
    render(() => (
      <InheritanceCard store={store} name="w_main" ancestors={["w_base"]} />
    ));
    fireEvent.click(screen.getByText("w_base"));
    const actions = captured.filter(a => a.tag === "objects" && a.action.type === "select");
    expect(actions.length).toBe(1);
    expect(actions[0]).toEqual({ tag: "objects", action: { type: "select", name: "w_base" } });
  });
});
