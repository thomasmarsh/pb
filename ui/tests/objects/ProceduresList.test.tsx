// tests/objects/ProceduresList.test.tsx — Tests for the ProceduresList
// component's embedded mode (Plan 211 Phase B — embeds inside Browser's
// Procedures tab).

import { describe, it, expect } from "vitest";
import { render, screen } from "@solidjs/testing-library";
import { createTestStore } from "../helpers.js";
import { ProceduresList } from "../../app/src/views/features/objects/ProceduresList.js";

describe("ProceduresList component", () => {
  it("renders its own search input by default", () => {
    const { store } = createTestStore();
    render(() => <ProceduresList store={store} />);
    expect(screen.queryByPlaceholderText("Search procedures or objects…")).not.toBeNull();
  });

  it("embedded hides the free-text search input", () => {
    const { store } = createTestStore();
    render(() => <ProceduresList store={store} embedded />);
    expect(screen.queryByPlaceholderText("Search procedures or objects…")).toBeNull();
  });
});
