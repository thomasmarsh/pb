// tests/features/tables.test.ts — Tests for tables feature reducer.

import { describe, it, expect } from "vitest";
import { Effect } from "../../src/core/effect.js";
import { createTestStore } from "../test-store.js";
import { tablesReducer, initialTablesState, type TablesEnv } from "../../src/features/tables/reducer.js";
import type { TableSummary, TableDetail } from "../../src/types/api.js";

const mockEnv: TablesEnv = {
  getTables:       () => Effect.none(),
  getTableDetail:  () => Effect.none(),
  navigate:        () => Effect.none(),
};

const row = (name: string): TableSummary => ({
  table_name: name, dw_count: 1, ps_count: 2, file_count: 3,
});

const detail: TableDetail = {
  table_name: "orders",
  dw_count: 1,
  ps_count: 2,
  datawindows: [{ dw_name: "dw_orders", file: "a.srd" }],
  columns: [{ dw_name: "dw_orders", column_fqn: "orders.id", column_name: "id" }],
  where: [],
  procedures: [
    { object: "n_svc", proc_name: "get_orders", operation: "SELECT" },
    { object: "n_svc", proc_name: "add_order",  operation: "INSERT" },
  ],
};

describe("tables reducer", () => {
  describe("tables/search", () => {
    it("sets q and loading, navigates to tables route", () => {
      const navigateCalls: string[] = [];
      const env: TablesEnv = {
        ...mockEnv,
        navigate: (action) => { navigateCalls.push(action.route.view); return Effect.none(); },
      };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ type: "search", q: "ord" }, (s) => {
        s.q = "ord";
        s.loading = true;
      });
      expect(navigateCalls).toEqual(["tables"]);
    });

    it("fires getTables effect; receive populates items", () => {
      const items = [row("orders"), row("customers")];
      const env: TablesEnv = { ...mockEnv, getTables: () => Effect.send(items) };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ type: "search", q: "" }, (s) => {
        s.q = "";
        s.loading = true;
      });
      ts.receive({ type: "loaded", items }, (s) => {
        s.items = items;
        s.total = 2;
        s.loading = false;
      });
    });
  });

  describe("tables/loaded", () => {
    it("populates items + total, clears loading", () => {
      const items = [row("orders")];
      const ts = createTestStore(tablesReducer, mockEnv, initialTablesState);
      ts.send({ type: "loaded", items }, (s) => {
        s.items = items;
        s.total = 1;
        s.loading = false;
      });
    });

    it("total reflects item count (not a separate field from backend)", () => {
      const items = [row("a"), row("b"), row("c")];
      const ts = createTestStore(tablesReducer, mockEnv, initialTablesState);
      ts.send({ type: "loaded", items }, (s) => {
        s.items = items;
        s.total = 3;
        s.loading = false;
      });
    });
  });

  describe("tables/select", () => {
    it("clears detail + error and navigates to tableDetail route", () => {
      const navigateRoutes: object[] = [];
      const env: TablesEnv = {
        ...mockEnv,
        navigate: (action) => { navigateRoutes.push(action.route); return Effect.none(); },
      };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ type: "select", name: "orders" }, (s) => {
        s.detail = null;
        s.error  = null;
      });
      expect(navigateRoutes).toEqual([{ view: "tableDetail", name: "orders" }]);
    });

    it("fires getTableDetail; receive populates detail", () => {
      const env: TablesEnv = { ...mockEnv, getTableDetail: () => Effect.send(detail) };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ type: "select", name: "orders" }, (s) => {
        s.detail = null;
        s.error  = null;
      });
      ts.receive({ type: "detail-loaded", detail }, (s) => {
        s.detail = detail;
        s.loading = false;
      });
    });

    it("fires getTableDetail; rejection maps to detail-error", async () => {
      const env: TablesEnv = {
        ...mockEnv,
        getTableDetail: () => Effect.fromPromise(() => Promise.reject(new Error("timeout"))),
      };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ type: "select", name: "orders" }, (s) => {
        s.detail = null;
        s.error  = null;
      });
      await ts.drain();
      ts.receive({ type: "detail-error", error: "timeout" }, (s) => {
        s.error   = "timeout";
        s.loading = false;
      });
    });
  });

  describe("tables/detail-loaded", () => {
    it("sets detail and clears loading", () => {
      const ts = createTestStore(tablesReducer, mockEnv, initialTablesState);
      ts.send({ type: "detail-loaded", detail }, (s) => {
        s.detail  = detail;
        s.loading = false;
      });
    });
  });

  describe("tables/detail-error", () => {
    it("records error string and clears loading", () => {
      const ts = createTestStore(tablesReducer, mockEnv, initialTablesState);
      ts.send({ type: "detail-error", error: "not found" }, (s) => {
        s.error   = "not found";
        s.loading = false;
      });
    });
  });

  describe("tables/back", () => {
    it("clears detail + error and navigates to tables route", () => {
      const navigateRoutes: object[] = [];
      const env: TablesEnv = {
        ...mockEnv,
        navigate: (action) => { navigateRoutes.push(action.route); return Effect.none(); },
      };
      const ts = createTestStore(tablesReducer, env, {
        ...initialTablesState,
        detail,
        error: null,
      });
      ts.send({ type: "back" }, (s) => {
        s.detail = null;
        s.error  = null;
      });
      expect(navigateRoutes).toEqual([{ view: "tables" }]);
    });

    it("clears error when navigating back", () => {
      const ts = createTestStore(tablesReducer, mockEnv, {
        ...initialTablesState,
        detail: null,
        error: "previous error",
      });
      ts.send({ type: "back" }, (s) => {
        s.detail = null;
        s.error  = null;
      });
    });
  });
});
