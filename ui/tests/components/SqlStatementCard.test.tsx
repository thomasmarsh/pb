// tests/components/SqlStatementCard.test.tsx — Tests for SqlStatementCard lint badges.

import { describe, it, expect } from "vitest";
import { render } from "@solidjs/testing-library";
import { SqlStatementCard } from "../../app/src/views/components/detail/SqlStatementCard.js";
import { createTestStore } from "../helpers.js";
import type { SqlStatementRow } from "@pb/platform";

function makeStmt(overrides?: Partial<SqlStatementRow>): SqlStatementRow {
  return {
    line: 1,
    operation: "SELECT",
    raw_sql: "SELECT * FROM customer",
    formatted_sql: "SELECT * FROM customer",
    tables: [],
    columns: null,
    has_into: false,
    has_cursor: false,
    parse_ok: true,
    lint_warnings: [],
    ...overrides,
  };
}

describe("SqlStatementCard lint badges", () => {
  it("renders no lint badge when lint_warnings is empty", () => {
    const { store } = createTestStore({});
    const { container } = render(() => <SqlStatementCard stmt={makeStmt()} store={store} />);
    expect(container.querySelector(".badge-warn")).toBeNull();
    expect(container.querySelector(".badge-error")).toBeNull();
  });

  it("renders a warning badge for select_star", () => {
    const { store } = createTestStore({});
    const { getByText } = render(() => <SqlStatementCard stmt={makeStmt({ lint_warnings: ["select_star"] })} store={store} />);
    const badge = getByText("SELECT *");
    expect(badge.className).toContain("badge-warn");
  });

  it("renders an error badge for write_no_where", () => {
    const { store } = createTestStore({});
    const { getByText } = render(() => <SqlStatementCard stmt={makeStmt({ operation: "UPDATE", lint_warnings: ["write_no_where"] })} store={store} />);
    const badge = getByText("No WHERE");
    expect(badge.className).toContain("badge-error");
  });

  it("renders multiple lint badges", () => {
    const { store } = createTestStore({});
    const { getByText } = render(() => <SqlStatementCard stmt={makeStmt({ lint_warnings: ["select_star", "sql_in_loop"] })} store={store} />);
    expect(getByText("SELECT *")).toBeDefined();
    expect(getByText("In loop")).toBeDefined();
  });
});
