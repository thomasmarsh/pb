// tests/features/tables.test.ts — Tests for tables feature reducer.

import { describe, it, expect } from "vitest";
import { Effect } from "@pb/core";
import { createTestStore } from "../test-store.js";
import { tablesReducer, initialTablesState, type TablesEnv } from "@pb/platform";
import type { TablesState } from "@pb/platform";
import type { TableSummary, TableDetail, ColumnUsageResponse, CoUpdateRitualsResponse } from "@pb/platform";

const mockEnv: TablesEnv = {
  getTables:           () => Effect.none(),
  getTableDetail:      () => Effect.none(),
  getColumnUsage:      () => Effect.none(),
  getCoUpdateRituals:  () => Effect.none(),
  navigate:            () => Effect.none(),
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
  columns_detail: [],
  where: [],
  procedures: [
    { object: "n_svc", proc_name: "get_orders", operation: "SELECT" },
    { object: "n_svc", proc_name: "add_order",  operation: "INSERT" },
  ],
  impact: { direct: [], inherited: [] },
};

describe("tables reducer", () => {
  describe("tables/search", () => {
    it("sets q and loading, navigates to tables route", () => {
      const navigateCalls: string[] = [];
      const env: TablesEnv = {
        ...mockEnv,
        navigate: (action) => { if (action.tag === "navigate") navigateCalls.push(action.route.view); return Effect.none(); },
      };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "search", q: "ord" }, (s) => {
        s.q = "ord";
        s.loading = true;
      });
      expect(navigateCalls).toEqual(["tables"]);
    });

    it("fires getTables effect; receive populates items", () => {
      const items = [row("orders"), row("customers")];
      const env: TablesEnv = { ...mockEnv, getTables: () => Effect.send(items) };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "search", q: "" }, (s) => {
        s.q = "";
        s.loading = true;
      });
      ts.receive({ tag: "loaded", items }, (s) => {
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
      ts.send({ tag: "loaded", items }, (s) => {
        s.items = items;
        s.total = 1;
        s.loading = false;
      });
    });

    it("total reflects item count (not a separate field from backend)", () => {
      const items = [row("a"), row("b"), row("c")];
      const ts = createTestStore(tablesReducer, mockEnv, initialTablesState);
      ts.send({ tag: "loaded", items }, (s) => {
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
        navigate: (action) => { if (action.tag === "navigate") navigateRoutes.push(action.route); return Effect.none(); },
      };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "select", name: "orders" }, (s) => {
        s.detail = null;
        s.error  = null;
      });
      expect(navigateRoutes).toEqual([{ view: "tableDetail", name: "orders" }]);
    });

    it("fires getTableDetail; receive populates detail", () => {
      const env: TablesEnv = { ...mockEnv, getTableDetail: () => Effect.send(detail) };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "select", name: "orders" }, (s) => {
        s.detail = null;
        s.error  = null;
      });
      ts.receive({ tag: "detail-loaded", detail }, (s) => {
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
      ts.send({ tag: "select", name: "orders" }, (s) => {
        s.detail = null;
        s.error  = null;
      });
      await ts.drain();
      ts.receive({ tag: "detail-error", error: "timeout" }, (s) => {
        s.error   = "timeout";
        s.loading = false;
      });
    });
  });

  describe("tables/detail-loaded", () => {
    it("sets detail and clears loading", () => {
      const ts = createTestStore(tablesReducer, mockEnv, initialTablesState);
      ts.send({ tag: "detail-loaded", detail }, (s) => {
        s.detail  = detail;
        s.loading = false;
      });
    });
  });

  describe("tables/detail-error", () => {
    it("records error string and clears loading", () => {
      const ts = createTestStore(tablesReducer, mockEnv, initialTablesState);
      ts.send({ tag: "detail-error", error: "not found" }, (s) => {
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
        navigate: (action) => { if (action.tag === "navigate") navigateRoutes.push(action.route); return Effect.none(); },
      };
      const ts = createTestStore(tablesReducer, env, {
        ...initialTablesState,
        detail,
        error: null,
      } as TablesState);
      ts.send({ tag: "back" }, (s) => {
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
      } as TablesState);
      ts.send({ tag: "back" }, (s) => {
        s.detail = null;
        s.error  = null;
      });
    });
  });

  describe("tables/column-usage-load", () => {
    const usage: ColumnUsageResponse = {
      dead: [{ namespace: null, table: "afxtable", column: "tablename" }],
      write_only: [],
      read_only: [],
      read_write: [],
    };

    it("sets columnUsageLoading and fires getColumnUsage", () => {
      const env: TablesEnv = { ...mockEnv, getColumnUsage: () => Effect.send(usage) };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "column-usage-load" }, (s) => {
        s.columnUsageLoading = true;
      });
      ts.receive({ tag: "column-usage-loaded", data: usage }, (s) => {
        s.columnUsage = usage;
        s.columnUsageLoading = false;
      });
    });

    it("does nothing if already loaded", () => {
      const state: TablesState = { ...initialTablesState, columnUsage: usage };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "column-usage-load" }, () => {});
    });

    it("does nothing if a load is already in flight", () => {
      const state: TablesState = { ...initialTablesState, columnUsageLoading: true };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "column-usage-load" }, () => {});
    });

    it("fires getColumnUsage; rejection maps to column-usage-error", async () => {
      const env: TablesEnv = {
        ...mockEnv,
        getColumnUsage: () => Effect.fromPromise(() => Promise.reject(new Error("timeout"))),
      };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "column-usage-load" }, (s) => {
        s.columnUsageLoading = true;
      });
      await ts.drain();
      ts.receive({ tag: "column-usage-error", error: "timeout" }, (s) => {
        s.columnUsage = { error: "timeout" };
        s.columnUsageLoading = false;
      });
    });
  });

  describe("tables/column-usage-loaded", () => {
    it("stores the usage and clears loading", () => {
      const usage: ColumnUsageResponse = { dead: [], write_only: [], read_only: [], read_write: [] };
      const state: TablesState = { ...initialTablesState, columnUsageLoading: true };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "column-usage-loaded", data: usage }, (s) => {
        s.columnUsage = usage;
        s.columnUsageLoading = false;
      });
    });
  });

  describe("tables/column-usage-error", () => {
    it("stores the error and clears loading", () => {
      const state: TablesState = { ...initialTablesState, columnUsageLoading: true };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "column-usage-error", error: "boom" }, (s) => {
        s.columnUsage = { error: "boom" };
        s.columnUsageLoading = false;
      });
    });
  });

  describe("tables/co-update-rituals-load", () => {
    const rituals: CoUpdateRitualsResponse = {
      rituals: [
        {
          column_a: { namespace: null, table: "misth_final_ypal", column: "kodfinal" },
          column_b: { namespace: null, table: "misth_final_ypal", column: "kodypal" },
          co_write_support: 3,
          violations: [],
        },
      ],
    };

    it("sets coUpdateRitualsLoading and fires getCoUpdateRituals", () => {
      const env: TablesEnv = { ...mockEnv, getCoUpdateRituals: () => Effect.send(rituals) };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "co-update-rituals-load" }, (s) => {
        s.coUpdateRitualsLoading = true;
      });
      ts.receive({ tag: "co-update-rituals-loaded", data: rituals }, (s) => {
        s.coUpdateRituals = rituals;
        s.coUpdateRitualsLoading = false;
      });
    });

    it("does nothing if already loaded", () => {
      const state: TablesState = { ...initialTablesState, coUpdateRituals: rituals };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "co-update-rituals-load" }, () => {});
    });

    it("does nothing if a load is already in flight", () => {
      const state: TablesState = { ...initialTablesState, coUpdateRitualsLoading: true };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "co-update-rituals-load" }, () => {});
    });

    it("fires getCoUpdateRituals; rejection maps to co-update-rituals-error", async () => {
      const env: TablesEnv = {
        ...mockEnv,
        getCoUpdateRituals: () => Effect.fromPromise(() => Promise.reject(new Error("timeout"))),
      };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "co-update-rituals-load" }, (s) => {
        s.coUpdateRitualsLoading = true;
      });
      await ts.drain();
      ts.receive({ tag: "co-update-rituals-error", error: "timeout" }, (s) => {
        s.coUpdateRituals = { error: "timeout" };
        s.coUpdateRitualsLoading = false;
      });
    });
  });

  describe("tables/co-update-rituals-loaded", () => {
    it("stores the rituals and clears loading", () => {
      const rituals: CoUpdateRitualsResponse = { rituals: [] };
      const state: TablesState = { ...initialTablesState, coUpdateRitualsLoading: true };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "co-update-rituals-loaded", data: rituals }, (s) => {
        s.coUpdateRituals = rituals;
        s.coUpdateRitualsLoading = false;
      });
    });
  });

  describe("tables/co-update-rituals-error", () => {
    it("stores the error and clears loading", () => {
      const state: TablesState = { ...initialTablesState, coUpdateRitualsLoading: true };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "co-update-rituals-error", error: "boom" }, (s) => {
        s.coUpdateRituals = { error: "boom" };
        s.coUpdateRitualsLoading = false;
      });
    });
  });
});
