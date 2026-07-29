// tests/features/datawindows.test.ts — Tests for datawindows feature reducer.

import { describe, it, expect } from "vitest";
import { Effect } from "@pb/core";
import { createTestStore } from "../test-store.js";
import { datawindowsReducer, initialDatawindowsState, type DatawindowsEnv } from "@pb/platform";
import type { ListObjectsResponse, DwDetailResponse, FootprintResponse, DatawindowsState } from "@pb/platform";

const mockEnv: DatawindowsEnv = {
  getObjects: () => Effect.none(),
  getDW: () => Effect.none(),
  getDwLayout: () => Effect.none(),
  getFootprint: () => Effect.none(),
  navigate: () => Effect.none(),
};

describe("datawindows reducer", () => {
  describe("datawindows/search", () => {
    it("sets q, triggers loading, and emits navigate", () => {
      const navigateCalls: string[] = [];
      const env: DatawindowsEnv = {
        ...mockEnv,
        navigate: (action) => { if (action.tag === "navigate") navigateCalls.push(action.route.view); return Effect.none(); },
      };
      const ts = createTestStore(datawindowsReducer, env, initialDatawindowsState);
      ts.send({ tag: "search", q: "test" }, (s) => {
        s.q = "test";
        s.loading = true;
      });
      expect(navigateCalls).toEqual(["datawindows"]);
    });

    it("fires getObjects effect via receive", () => {
      const data: ListObjectsResponse = {
        items: [{ name: "dw1", kind: "datawindow", category: "datawindow", file: "f", ancestor: null }],
        total: 1, offset: 0, limit: 200,
      };
      const env: DatawindowsEnv = { ...mockEnv, getObjects: () => Effect.send(data) };
      const ts = createTestStore(datawindowsReducer, env, initialDatawindowsState);
      ts.send({ tag: "search", q: "dw" }, (s) => {
        s.q = "dw";
        s.loading = true;
      });
      ts.receive({ tag: "loaded", data }, (s) => {
        s.items = data.items;
        s.total = 1;
        s.loading = false;
      });
    });
  });

  describe("datawindows/loaded", () => {
    it("populates items, total, and clears loading", () => {
      const data: ListObjectsResponse = {
        items: [
          { name: "dw1", kind: "datawindow", category: "datawindow", file: "f", ancestor: null },
          { name: "dw2", kind: "datawindow", category: "datawindow", file: "f", ancestor: null },
        ],
        total: 2, offset: 0, limit: 200,
      };
      const ts = createTestStore(datawindowsReducer, mockEnv, initialDatawindowsState);
      ts.send({ tag: "loaded", data }, (s) => {
        s.items = data.items;
        s.total = 2;
        s.loading = false;
      });
    });
  });

  describe("datawindows/select", () => {
    it("clears dwDetail and emits navigate with dwDetail route", () => {
      const navigateRoutes: object[] = [];
      const env: DatawindowsEnv = {
        ...mockEnv,
        navigate: (action) => { if (action.tag === "navigate") navigateRoutes.push(action.route); return Effect.none(); },
      };
      const ts = createTestStore(datawindowsReducer, env, initialDatawindowsState);
      ts.send({ tag: "select", name: "MyDW" }, (s) => {
        s.dwDetail = null;
      });
      expect(navigateRoutes).toEqual([{ view: "dwDetail", name: "MyDW" }]);
    });

    it("fires getDW effect via receive", () => {
      const detailData: DwDetailResponse = { name: "MyDW", source: "select 1" } as DwDetailResponse;
      const env: DatawindowsEnv = { ...mockEnv, getDW: () => Effect.send(detailData) };
      const ts = createTestStore(datawindowsReducer, env, initialDatawindowsState);
      ts.send({ tag: "select", name: "MyDW" }, (s) => {
        s.dwDetail = null;
      });
      ts.receive({ tag: "detail-loaded", data: detailData }, (s) => {
        s.dwDetail = { ...detailData, loading: false };
      });
    });

    it("resets footprint state when navigating to a (possibly different) DW", () => {
      const state: DatawindowsState = {
        ...initialDatawindowsState,
        footprint: { object: "d_old", proc_name: null, kind: "dw_retrieve", statements: [], blast_radius: [] },
        footprintLoading: true,
      };
      const ts = createTestStore(datawindowsReducer, mockEnv, state);
      ts.send({ tag: "select", name: "d_new" }, (s) => {
        s.dwDetail = null;
        s.dwLayout = null;
        s.footprint = null;
        s.footprintLoading = false;
      });
    });
  });

  describe("datawindows/detail-loaded", () => {
    it("populates dwDetail and clears loading", () => {
      const data: DwDetailResponse = { name: "dw1", source: "select 1" } as DwDetailResponse;
      const ts = createTestStore(datawindowsReducer, mockEnv, initialDatawindowsState);
      ts.send({ tag: "detail-loaded", data }, (s) => {
        s.dwDetail = { ...data, loading: false };
      });
    });
  });

  describe("datawindows/detail-error", () => {
    it("records error string", () => {
      const ts = createTestStore(datawindowsReducer, mockEnv, initialDatawindowsState);
      ts.send({ tag: "detail-error", error: "timeout" }, (s) => {
        s.dwDetail = { error: "timeout" };
      });
    });
  });

  describe("datawindows/footprint-load", () => {
    it("sets footprintLoading and fires getFootprint", () => {
      const ts = createTestStore(datawindowsReducer, mockEnv, initialDatawindowsState);
      ts.send({ tag: "footprint-load", dwName: "d_foo" }, (s) => {
        s.footprintLoading = true;
      });
    });

    it("does nothing if already loaded for the same DW", () => {
      const loaded: FootprintResponse = { object: "d_foo", proc_name: null, kind: "dw_retrieve", statements: [], blast_radius: [] };
      const state: DatawindowsState = { ...initialDatawindowsState, footprint: loaded };
      const ts = createTestStore(datawindowsReducer, mockEnv, state);
      ts.send({ tag: "footprint-load", dwName: "d_foo" }, () => {});
    });

    it("does nothing if a load is already in flight", () => {
      const state: DatawindowsState = { ...initialDatawindowsState, footprintLoading: true };
      const ts = createTestStore(datawindowsReducer, mockEnv, state);
      ts.send({ tag: "footprint-load", dwName: "d_foo" }, () => {});
    });
  });

  describe("datawindows/footprint-loaded", () => {
    it("stores the footprint and clears loading", () => {
      const data: FootprintResponse = {
        object: "d_foo",
        proc_name: null,
        kind: "dw_retrieve",
        statements: [{
          stmt_key: "dw:d_foo",
          file: "d_foo.srd",
          line: null,
          legs: [{ column: { namespace: null, table: "usrmembers", column: "koduser" }, leg_kind: "retrieve", leg_source: "dw_retrieve" }],
        }],
        blast_radius: [],
      };
      const state: DatawindowsState = { ...initialDatawindowsState, footprintLoading: true };
      const ts = createTestStore(datawindowsReducer, mockEnv, state);
      ts.send({ tag: "footprint-loaded", data }, (s) => {
        s.footprint = data;
        s.footprintLoading = false;
      });
    });
  });

  describe("datawindows/footprint-error", () => {
    it("stores the error and clears loading", () => {
      const state: DatawindowsState = { ...initialDatawindowsState, footprintLoading: true };
      const ts = createTestStore(datawindowsReducer, mockEnv, state);
      ts.send({ tag: "footprint-error", error: "boom" }, (s) => {
        s.footprint = { error: "boom" };
        s.footprintLoading = false;
      });
    });
  });
});
