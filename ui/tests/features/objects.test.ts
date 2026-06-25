// tests/features/objects.test.ts — Tests for objects feature reducer.

import { describe, it } from "vitest";
import { Effect } from "@pb/core";
import { createTestStore } from "../test-store.js";
import { objectsReducer, initialObjectsState, type ObjectsEnv } from "@pb/platform";
import type { ListObjectsResponse } from "@pb/platform";

const mockEnv: ObjectsEnv = {
  getObjects: () => Effect.none(),
  getAllObjects: () => Effect.none(),
  getObject: () => Effect.none(),
  getObjectSource: () => Effect.none(),
  getObjectAst: () => Effect.none(),
  getObjectLayout: () => Effect.none(),
  getProcedure: () => Effect.none(),
  getProcedures: () => Effect.none(),
  navigate: () => Effect.none(),
};

describe("objects reducer", () => {
  describe("objects/search", () => {
    it("sets q and triggers loading", () => {
      const ts = createTestStore(objectsReducer, mockEnv, initialObjectsState);
      ts.send({ tag: "search", q: "test" }, (s) => {
        s.q = "test";
        s.loading = true;
      });
    });
  });

  describe("objects/filter-kind", () => {
    it("sets kind and triggers loading", () => {
      const ts = createTestStore(objectsReducer, mockEnv, initialObjectsState);
      ts.send({ tag: "filter-kind", kind: "datawindow" }, (s) => {
        s.kind = "datawindow";
        s.loading = true;
      });
    });
  });

  describe("objects/sort", () => {
    it("sets sort col and triggers loading", () => {
      const ts = createTestStore(objectsReducer, mockEnv, initialObjectsState);
      ts.send({ tag: "sort", col: "kind" }, (s) => {
        s.sort = "kind";
        s.loading = true;
      });
    });

    it("toggles order when sorting by the same col", () => {
      const ts = createTestStore(objectsReducer, mockEnv, initialObjectsState);
      ts.send({ tag: "sort", col: "name" }, (s) => {
        s.order = "desc";
        s.loading = true;
      });
    });
  });

  describe("objects/page", () => {
    it("sets offset and triggers loading", () => {
      const ts = createTestStore(objectsReducer, mockEnv, initialObjectsState);
      ts.send({ tag: "page", offset: 100 }, (s) => {
        s.offset = 100;
        s.loading = true;
      });
    });
  });

  describe("objects/loaded", () => {
    it("populates items, total, and clears loading", () => {
      const data: ListObjectsResponse = {
        items: [{ name: "foo", kind: "powerscript", file: "x", ancestor: null }],
        total: 42, offset: 0, limit: 100,
      };
      const ts = createTestStore(objectsReducer, mockEnv, initialObjectsState);
      ts.send({ tag: "loaded", data }, (s) => {
        s.items = data.items;
        s.total = 42;
        s.loading = false;
      });
    });
  });
});
