// tests/tables/TableList.test.tsx — Tests for the TableList component's
// embedded mode (Plan 211 Phase B — embeds inside Browser's Tables tab).

import { describe, it, expect } from "vitest";
import { render, screen } from "@solidjs/testing-library";
import { createTestStore } from "../helpers.js";
import { TableList } from "../../app/src/views/features/tables/TableList.js";
import { initialTablesState } from "@pb/platform";

describe("TableList component", () => {
  it("renders its own search input by default", () => {
    const { store } = createTestStore({ tables: { ...initialTablesState, items: [] } });
    render(() => <TableList store={store} />);
    expect(screen.queryByPlaceholderText("Search tables…")).not.toBeNull();
  });

  it("embedded hides the free-text search input", () => {
    const { store } = createTestStore({ tables: { ...initialTablesState, items: [] } });
    render(() => <TableList store={store} embedded />);
    expect(screen.queryByPlaceholderText("Search tables…")).toBeNull();
  });
});
