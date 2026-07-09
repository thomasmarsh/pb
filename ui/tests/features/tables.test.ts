// tests/features/tables.test.ts — Tests for tables feature reducer.

import { describe, it, expect } from "vitest";
import { Effect } from "@pb/core";
import { createTestStore } from "../test-store.js";
import { tablesReducer, initialTablesState, type TablesEnv } from "@pb/platform";
import type { TablesState } from "@pb/platform";
import type { SchemaSummary, TableSummary, TableDetail, ColumnUsageResponse, CoUpdateRitualsResponse, DecompositionCandidatesResponse, ColumnAffinityResponse, StatsResponse } from "@pb/platform";

const mockEnv: TablesEnv = {
  getSchemas:          () => Effect.none(),
  getTables:           () => Effect.none(),
  getTableDetail:      () => Effect.none(),
  getColumnUsage:      () => Effect.none(),
  getCoUpdateRituals:  () => Effect.none(),
  getDecompositionCandidates: () => Effect.none(),
  getColumnAffinity:   () => Effect.none(),
  getStats:            () => Effect.none(),
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
  describe("tables/schemas-load", () => {
    const schemas: SchemaSummary[] = [
      { namespace: "clims", table_count: 42 },
      { namespace: "clims_archive", table_count: 1 },
    ];

    it("sets schemasLoading and fires getSchemas", () => {
      const env: TablesEnv = { ...mockEnv, getSchemas: () => Effect.send(schemas) };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "schemas-load" }, (s) => {
        s.schemasLoading = true;
      });
      ts.receive({ tag: "schemas-loaded", schemas }, (s) => {
        s.schemas = schemas;
        s.schemasLoading = false;
      });
    });

    it("does nothing if already loaded", () => {
      const state: TablesState = { ...initialTablesState, schemas };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "schemas-load" }, () => {});
    });

    it("does nothing if a load is already in flight", () => {
      const state: TablesState = { ...initialTablesState, schemasLoading: true };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "schemas-load" }, () => {});
    });

    it("fires getSchemas; rejection maps to schemas-error", async () => {
      const env: TablesEnv = {
        ...mockEnv,
        getSchemas: () => Effect.fromPromise(() => Promise.reject(new Error("timeout"))),
      };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "schemas-load" }, (s) => {
        s.schemasLoading = true;
      });
      await ts.drain();
      ts.receive({ tag: "schemas-error", error: "timeout" }, (s) => {
        s.schemasLoading = false;
      });
    });
  });

  describe("tables/stats-load", () => {
    // No default_namespace here on purpose: this describe block covers the
    // load-once mechanic in isolation. The "adopt default and cascade into
    // search" behavior has its own describe block below (tables/stats-loaded).
    const stats: StatsResponse = {
      default_namespace: null,
      objects: 0, procedures: 0, dw_controls: 0, dw_retrieve_tables: 0,
      dw_retrieve_columns: 0, inherits: 0, calls: 0, object_metrics: 0,
      tables: 0, by_kind: [], top_complex: [], top_pagerank: [],
    };

    it("sets statsLoading and fires getStats", () => {
      const env: TablesEnv = { ...mockEnv, getStats: () => Effect.send(stats) };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "stats-load" }, (s) => {
        s.statsLoading = true;
      });
      ts.receive({ tag: "stats-loaded", defaultNamespace: null }, (s) => {
        s.statsLoading = false;
      });
    });

    it("does nothing if already loaded", () => {
      const state: TablesState = { ...initialTablesState, defaultNamespace: "clims" };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "stats-load" }, () => {});
    });

    it("does nothing if a load is already in flight", () => {
      const state: TablesState = { ...initialTablesState, statsLoading: true };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "stats-load" }, () => {});
    });

    it("fires getStats; rejection maps to stats-error", async () => {
      const env: TablesEnv = {
        ...mockEnv,
        getStats: () => Effect.fromPromise(() => Promise.reject(new Error("timeout"))),
      };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "stats-load" }, (s) => {
        s.statsLoading = true;
      });
      await ts.drain();
      ts.receive({ tag: "stats-error" }, (s) => {
        s.statsLoading = false;
      });
    });
  });

  describe("tables/stats-loaded", () => {
    it("when the route hasn't picked a namespace, adopts the default and fires search", () => {
      const navigateRoutes: object[] = [];
      const tablesCalls: (string | undefined)[] = [];
      const items = [row("clinicalaccession")];
      const env: TablesEnv = {
        ...mockEnv,
        navigate: (action) => { if (action.tag === "navigate") navigateRoutes.push(action.route); return Effect.none(); },
        getTables: (ns) => { tablesCalls.push(ns); return Effect.send(items); },
      };
      const state: TablesState = { ...initialTablesState, statsLoading: true };
      const ts = createTestStore(tablesReducer, env, state);
      ts.send({ tag: "stats-loaded", defaultNamespace: "clims" }, (s) => {
        s.defaultNamespace = "clims";
        s.statsLoading = false;
        s.namespace = "clims";
        s.loading = true;
      });
      expect(navigateRoutes).toEqual([{ view: "tables", namespace: "clims" }]);
      expect(tablesCalls).toEqual(["clims"]);
      ts.receive({ tag: "loaded", items }, (s) => {
        s.items = items;
        s.total = 1;
        s.loading = false;
      });
    });

    it("when a namespace is already set (route-scoped), does not override it", () => {
      const state: TablesState = { ...initialTablesState, statsLoading: true, namespace: "clims_archive" };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "stats-loaded", defaultNamespace: "clims" }, (s) => {
        s.defaultNamespace = "clims";
        s.statsLoading = false;
      });
    });

    it("with no default namespace configured, does nothing further", () => {
      const state: TablesState = { ...initialTablesState, statsLoading: true };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "stats-loaded", defaultNamespace: null }, (s) => {
        s.statsLoading = false;
      });
    });
  });

  describe("tables/mount", () => {
    it("fresh mount, scoped: merges schemas-load + stats-load + search effects", () => {
      const schemas: SchemaSummary[] = [{ namespace: "clims", table_count: 5 }];
      const stats: StatsResponse = {
        default_namespace: "clims",
        objects: 0, procedures: 0, dw_controls: 0, dw_retrieve_tables: 0,
        dw_retrieve_columns: 0, inherits: 0, calls: 0, object_metrics: 0,
        tables: 0, by_kind: [], top_complex: [], top_pagerank: [],
      };
      const items = [row("clinicalaccession")];
      const navigateRoutes: object[] = [];
      const env: TablesEnv = {
        ...mockEnv,
        getSchemas: () => Effect.send(schemas),
        getStats: () => Effect.send(stats),
        getTables: () => Effect.send(items),
        navigate: (action) => { if (action.tag === "navigate") navigateRoutes.push(action.route); return Effect.none(); },
      };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "mount", namespace: "clims" }, (s) => {
        s.schemasLoading = true;
        s.statsLoading = true;
        s.namespace = "clims";
        s.loading = true;
      });
      ts.receive({ tag: "schemas-loaded", schemas }, (s) => {
        s.schemas = schemas;
        s.schemasLoading = false;
      });
      ts.receive({ tag: "stats-loaded", defaultNamespace: "clims" }, (s) => {
        s.defaultNamespace = "clims";
        s.statsLoading = false;
      });
      ts.receive({ tag: "loaded", items }, (s) => {
        s.items = items;
        s.total = 1;
        s.loading = false;
      });
      expect(navigateRoutes).toEqual([{ view: "tables", namespace: "clims" }]);
    });

    it("remount with matching namespace and items already loaded skips the search fetch", () => {
      const state: TablesState = {
        ...initialTablesState,
        items: [row("orders")], namespace: "clims",
        schemas: [{ namespace: "clims", table_count: 1 }],
        defaultNamespace: "clims",
      };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "mount", namespace: "clims" }, () => {});
    });

    it("remount with a different namespace re-fires the search fetch", () => {
      const items = [row("clims_archive_tbl")];
      const env: TablesEnv = { ...mockEnv, getTables: () => Effect.send(items) };
      const state: TablesState = {
        ...initialTablesState,
        items: [row("orders")], namespace: "clims",
        schemas: [{ namespace: "clims", table_count: 1 }],
        defaultNamespace: "clims",
      };
      const ts = createTestStore(tablesReducer, env, state);
      ts.send({ tag: "mount", namespace: "clims_archive" }, (s) => {
        s.namespace = "clims_archive";
        s.q = "";
        s.loading = true;
      });
      ts.receive({ tag: "loaded", items }, (s) => {
        s.items = items;
        s.total = 1;
        s.loading = false;
      });
    });
  });

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

    it("scoped to a namespace: sets namespace, navigates to the scoped route, fires getTables(namespace)", () => {
      const navigateRoutes: object[] = [];
      const tablesCalls: (string | undefined)[] = [];
      const items = [row("clinicalaccession")];
      const env: TablesEnv = {
        ...mockEnv,
        navigate: (action) => { if (action.tag === "navigate") navigateRoutes.push(action.route); return Effect.none(); },
        getTables: (ns) => { tablesCalls.push(ns); return Effect.send(items); },
      };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "search", q: "", namespace: "clims" }, (s) => {
        s.q = "";
        s.namespace = "clims";
        s.loading = true;
      });
      expect(navigateRoutes).toEqual([{ view: "tables", namespace: "clims" }]);
      expect(tablesCalls).toEqual(["clims"]);
      ts.receive({ tag: "loaded", items }, (s) => {
        s.items = items;
        s.total = 1;
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
        s.decompositionCandidates = null;
        s.decompositionCandidatesLoading = false;
      });
      expect(navigateRoutes).toEqual([{ view: "tableDetail", name: "orders" }]);
    });

    it("fires getTableDetail; receive populates detail", () => {
      const env: TablesEnv = { ...mockEnv, getTableDetail: () => Effect.send(detail) };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "select", name: "orders" }, (s) => {
        s.detail = null;
        s.error  = null;
        s.decompositionCandidates = null;
        s.decompositionCandidatesLoading = false;
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
        s.decompositionCandidates = null;
        s.decompositionCandidatesLoading = false;
      });
      await ts.drain();
      ts.receive({ tag: "detail-error", error: "timeout" }, (s) => {
        s.error   = "timeout";
        s.loading = false;
      });
    });

    it("scoped to a namespace: navigates to the scoped tableDetail route, fires getTableDetail(name, namespace)", () => {
      const navigateRoutes: object[] = [];
      const detailCalls: (string | undefined)[] = [];
      const env: TablesEnv = {
        ...mockEnv,
        navigate: (action) => { if (action.tag === "navigate") navigateRoutes.push(action.route); return Effect.none(); },
        getTableDetail: (_n, ns) => { detailCalls.push(ns); return Effect.send(detail); },
      };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "select", name: "clinicalaccession", namespace: "clims_common" }, (s) => {
        s.detail = null;
        s.error  = null;
        s.decompositionCandidates = null;
        s.decompositionCandidatesLoading = false;
      });
      expect(navigateRoutes).toEqual([{ view: "tableDetail", name: "clinicalaccession", namespace: "clims_common" }]);
      expect(detailCalls).toEqual(["clims_common"]);
      ts.receive({ tag: "detail-loaded", detail }, (s) => {
        s.detail = detail;
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

    it("preserves the scoping namespace when navigating back to the scoped tables route", () => {
      const navigateRoutes: object[] = [];
      const env: TablesEnv = {
        ...mockEnv,
        navigate: (action) => { if (action.tag === "navigate") navigateRoutes.push(action.route); return Effect.none(); },
      };
      const ts = createTestStore(tablesReducer, env, {
        ...initialTablesState,
        detail,
        error: null,
        namespace: "clims",
      } as TablesState);
      ts.send({ tag: "back" }, (s) => {
        s.detail = null;
        s.error  = null;
      });
      expect(navigateRoutes).toEqual([{ view: "tables", namespace: "clims" }]);
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

  describe("tables/decomposition-candidates-load", () => {
    const candidates: DecompositionCandidatesResponse = {
      table: "misth_final_ypal",
      namespace: null,
      candidates: [
        {
          columns: ["kodfinal", "kodxrisi", "kodypal"],
          similarity: 0.9,
          ritual_support: 3,
          unenforced_fk_count: 0,
          coslice_size: 120,
          score: 0.025,
          paths: [],
        },
      ],
    };

    it("sets decompositionCandidatesLoading and fires getDecompositionCandidates", () => {
      const env: TablesEnv = { ...mockEnv, getDecompositionCandidates: () => Effect.send(candidates) };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "decomposition-candidates-load", tableName: "misth_final_ypal" }, (s) => {
        s.decompositionCandidatesLoading = true;
      });
      ts.receive({ tag: "decomposition-candidates-loaded", data: candidates }, (s) => {
        s.decompositionCandidates = candidates;
        s.decompositionCandidatesLoading = false;
      });
    });

    it("does nothing if already loaded for this table", () => {
      const state: TablesState = { ...initialTablesState, decompositionCandidates: candidates };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "decomposition-candidates-load", tableName: "misth_final_ypal" }, () => {});
    });

    it("does nothing if a load is already in flight", () => {
      const state: TablesState = { ...initialTablesState, decompositionCandidatesLoading: true };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "decomposition-candidates-load", tableName: "misth_final_ypal" }, () => {});
    });

    it("re-fires when the table name differs from what's loaded", () => {
      const state: TablesState = { ...initialTablesState, decompositionCandidates: candidates };
      const other: DecompositionCandidatesResponse = { table: "orders", namespace: null, candidates: [] };
      const env: TablesEnv = { ...mockEnv, getDecompositionCandidates: () => Effect.send(other) };
      const ts = createTestStore(tablesReducer, env, state);
      ts.send({ tag: "decomposition-candidates-load", tableName: "orders" }, (s) => {
        s.decompositionCandidatesLoading = true;
      });
      ts.receive({ tag: "decomposition-candidates-loaded", data: other }, (s) => {
        s.decompositionCandidates = other;
        s.decompositionCandidatesLoading = false;
      });
    });

    it("fires getDecompositionCandidates; rejection maps to decomposition-candidates-error", async () => {
      const env: TablesEnv = {
        ...mockEnv,
        getDecompositionCandidates: () => Effect.fromPromise(() => Promise.reject(new Error("timeout"))),
      };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "decomposition-candidates-load", tableName: "misth_final_ypal" }, (s) => {
        s.decompositionCandidatesLoading = true;
      });
      await ts.drain();
      ts.receive({ tag: "decomposition-candidates-error", error: "timeout" }, (s) => {
        s.decompositionCandidates = { error: "timeout" };
        s.decompositionCandidatesLoading = false;
      });
    });

    it("threads namespace through to getDecompositionCandidates", () => {
      const calls: (string | undefined)[] = [];
      const env: TablesEnv = {
        ...mockEnv,
        getDecompositionCandidates: (_t, ns) => { calls.push(ns); return Effect.send(candidates); },
      };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "decomposition-candidates-load", tableName: "clinicalaccession", namespace: "clims_common" }, (s) => {
        s.decompositionCandidatesLoading = true;
      });
      expect(calls).toEqual(["clims_common"]);
      ts.receive({ tag: "decomposition-candidates-loaded", data: candidates }, (s) => {
        s.decompositionCandidates = candidates;
        s.decompositionCandidatesLoading = false;
      });
    });
  });

  describe("tables/decomposition-candidates-loaded", () => {
    it("stores the candidates and clears loading", () => {
      const data: DecompositionCandidatesResponse = { table: "orders", namespace: null, candidates: [] };
      const state: TablesState = { ...initialTablesState, decompositionCandidatesLoading: true };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "decomposition-candidates-loaded", data }, (s) => {
        s.decompositionCandidates = data;
        s.decompositionCandidatesLoading = false;
      });
    });
  });

  describe("tables/decomposition-candidates-error", () => {
    it("stores the error and clears loading", () => {
      const state: TablesState = { ...initialTablesState, decompositionCandidatesLoading: true };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "decomposition-candidates-error", error: "boom" }, (s) => {
        s.decompositionCandidates = { error: "boom" };
        s.decompositionCandidatesLoading = false;
      });
    });
  });

  describe("tables/column-affinity-load", () => {
    const affinity: ColumnAffinityResponse = {
      table: "misth_ypal",
      namespace: null,
      columns: ["name", "surname", "fathername"],
      co_access_matrix: [[27, 27, 26], [27, 27, 26], [26, 26, 26]],
      dendrogram: [
        { similarity: 1.0, members: ["name", "surname"] },
        { similarity: 0.963, members: ["fathername", "name", "surname"] },
      ],
    };

    it("sets columnAffinityLoading and fires getColumnAffinity", () => {
      const env: TablesEnv = { ...mockEnv, getColumnAffinity: () => Effect.send(affinity) };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "column-affinity-load", tableName: "misth_ypal" }, (s) => {
        s.columnAffinityLoading = true;
      });
      ts.receive({ tag: "column-affinity-loaded", data: affinity }, (s) => {
        s.columnAffinity = affinity;
        s.columnAffinityLoading = false;
      });
    });

    it("does nothing if already loaded for this table", () => {
      const state: TablesState = { ...initialTablesState, columnAffinity: affinity };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "column-affinity-load", tableName: "misth_ypal" }, () => {});
    });

    it("does nothing if a load is already in flight", () => {
      const state: TablesState = { ...initialTablesState, columnAffinityLoading: true };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "column-affinity-load", tableName: "misth_ypal" }, () => {});
    });

    it("re-fires when the table name differs from what's loaded", () => {
      const state: TablesState = { ...initialTablesState, columnAffinity: affinity };
      const other: ColumnAffinityResponse = { table: "orders", namespace: null, columns: [], co_access_matrix: [], dendrogram: [] };
      const env: TablesEnv = { ...mockEnv, getColumnAffinity: () => Effect.send(other) };
      const ts = createTestStore(tablesReducer, env, state);
      ts.send({ tag: "column-affinity-load", tableName: "orders" }, (s) => {
        s.columnAffinityLoading = true;
      });
      ts.receive({ tag: "column-affinity-loaded", data: other }, (s) => {
        s.columnAffinity = other;
        s.columnAffinityLoading = false;
      });
    });

    it("fires getColumnAffinity; rejection maps to column-affinity-error", async () => {
      const env: TablesEnv = {
        ...mockEnv,
        getColumnAffinity: () => Effect.fromPromise(() => Promise.reject(new Error("timeout"))),
      };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "column-affinity-load", tableName: "misth_ypal" }, (s) => {
        s.columnAffinityLoading = true;
      });
      await ts.drain();
      ts.receive({ tag: "column-affinity-error", error: "timeout" }, (s) => {
        s.columnAffinity = { error: "timeout" };
        s.columnAffinityLoading = false;
      });
    });

    it("threads namespace through to getColumnAffinity", () => {
      const calls: (string | undefined)[] = [];
      const env: TablesEnv = {
        ...mockEnv,
        getColumnAffinity: (_t, ns) => { calls.push(ns); return Effect.send(affinity); },
      };
      const ts = createTestStore(tablesReducer, env, initialTablesState);
      ts.send({ tag: "column-affinity-load", tableName: "clinicalaccession", namespace: "clims_common" }, (s) => {
        s.columnAffinityLoading = true;
      });
      expect(calls).toEqual(["clims_common"]);
      ts.receive({ tag: "column-affinity-loaded", data: affinity }, (s) => {
        s.columnAffinity = affinity;
        s.columnAffinityLoading = false;
      });
    });
  });

  describe("tables/column-affinity-loaded", () => {
    it("stores the affinity data and clears loading", () => {
      const data: ColumnAffinityResponse = { table: "orders", namespace: null, columns: [], co_access_matrix: [], dendrogram: [] };
      const state: TablesState = { ...initialTablesState, columnAffinityLoading: true };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "column-affinity-loaded", data }, (s) => {
        s.columnAffinity = data;
        s.columnAffinityLoading = false;
      });
    });
  });

  describe("tables/column-affinity-error", () => {
    it("stores the error and clears loading", () => {
      const state: TablesState = { ...initialTablesState, columnAffinityLoading: true };
      const ts = createTestStore(tablesReducer, mockEnv, state);
      ts.send({ tag: "column-affinity-error", error: "boom" }, (s) => {
        s.columnAffinity = { error: "boom" };
        s.columnAffinityLoading = false;
      });
    });
  });
});
