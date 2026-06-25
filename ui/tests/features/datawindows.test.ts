// tests/features/datawindows.test.ts — Tests for datawindows feature reducer.

import { describe, it, expect } from "vitest";
import { Effect } from "@pb/core";
import { createTestStore } from "../test-store.js";
import { datawindowsReducer, initialDatawindowsState, type DatawindowsEnv } from "../../src/features/datawindows/reducer.js";
import type { ListObjectsResponse, DwDetailResponse } from "../../src/types/api.js";

const mockEnv: DatawindowsEnv = {
  getObjects: () => Effect.none(),
  getDW: () => Effect.none(),
  getDwLayout: () => Effect.none(),
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
        items: [{ name: "dw1", kind: "datawindow", file: "f", ancestor: null }],
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
          { name: "dw1", kind: "datawindow", file: "f", ancestor: null },
          { name: "dw2", kind: "datawindow", file: "f", ancestor: null },
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
});
