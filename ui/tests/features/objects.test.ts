// tests/features/objects.test.ts — Tests for objects feature reducer.

import { describe, it } from "vitest";
import { Effect } from "@pb/core";
import { createTestStore } from "../test-store.js";
import { objectsReducer, initialObjectsState, type ObjectsEnv } from "@pb/platform";
import type { ListObjectsResponse, WiringDiagramResponse, FootprintResponse, SliceResult, ObjectsState } from "@pb/platform";

const mockEnv: ObjectsEnv = {
  getObjects: () => Effect.none(),
  getAllObjects: () => Effect.none(),
  getObject: () => Effect.none(),
  getObjectSource: () => Effect.none(),
  getObjectAst: () => Effect.none(),
  getObjectLayout: () => Effect.none(),
  getProcedure: () => Effect.none(),
  getProcedures: () => Effect.none(),
  getWiringDiagram: () => Effect.none(),
  getFootprint: () => Effect.none(),
  getSlice: () => Effect.none(),
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
        items: [{ name: "foo", kind: "powerscript", category: "userobject", file: "x", ancestor: null }],
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

  describe("objects/wiring-load", () => {
    it("sets wiringDiagramLoading and fires getWiringDiagram", () => {
      const ts = createTestStore(objectsReducer, mockEnv, initialObjectsState);
      ts.send({ tag: "wiring-load", objectName: "w_foo", procName: "of_bar" }, (s) => {
        s.wiringDiagramLoading = true;
      });
    });

    it("does nothing if already loaded for the same object/proc", () => {
      const loaded = { nodes: { w0: { tag: "WireReturn" as const } }, entry: "w0", sourceOriginal: null, procStartLine: null, object: "w_foo", proc: "of_bar" };
      const state: ObjectsState = { ...initialObjectsState, wiringDiagram: loaded };
      const ts = createTestStore(objectsReducer, mockEnv, state);
      ts.send({ tag: "wiring-load", objectName: "w_foo", procName: "of_bar" }, () => {});
    });

    it("does nothing if a load is already in flight", () => {
      const state: ObjectsState = { ...initialObjectsState, wiringDiagramLoading: true };
      const ts = createTestStore(objectsReducer, mockEnv, state);
      ts.send({ tag: "wiring-load", objectName: "w_foo", procName: "of_bar" }, () => {});
    });
  });

  describe("objects/wiring-loaded", () => {
    it("stores the diagram keyed by object/proc and clears loading", () => {
      const data: WiringDiagramResponse = { nodes: { w0: { tag: "WireReturn" } }, entry: "w0", sourceOriginal: null, procStartLine: 10 };
      const state: ObjectsState = { ...initialObjectsState, wiringDiagramLoading: true };
      const ts = createTestStore(objectsReducer, mockEnv, state);
      ts.send({ tag: "wiring-loaded", objectName: "w_foo", procName: "of_bar", data }, (s) => {
        s.wiringDiagram = { ...data, object: "w_foo", proc: "of_bar" };
        s.wiringDiagramLoading = false;
      });
    });
  });

  describe("objects/wiring-error", () => {
    it("stores the error and clears loading", () => {
      const state: ObjectsState = { ...initialObjectsState, wiringDiagramLoading: true };
      const ts = createTestStore(objectsReducer, mockEnv, state);
      ts.send({ tag: "wiring-error", error: "boom" }, (s) => {
        s.wiringDiagram = { error: "boom" };
        s.wiringDiagramLoading = false;
      });
    });
  });

  describe("objects/proc-select", () => {
    it("resets wiringDiagram, footprint, and sliceHighlight state when navigating to a (possibly different) procedure", () => {
      const state: ObjectsState = {
        ...initialObjectsState,
        wiringDiagram: { nodes: { w0: { tag: "WireReturn" as const } }, entry: "w0", sourceOriginal: null, procStartLine: null, object: "w_old", proc: "of_old" },
        wiringDiagramLoading: true,
        footprint: { object: "w_old", proc_name: "of_old", kind: "sql", statements: [], blast_radius: [] },
        footprintLoading: true,
        sliceHighlight: { origin: { object: "w_old", proc: "of_old", line: 1, var: null }, direction: "backward", steps: [], procedures_traversed: [], object: "w_old", proc: "of_old" },
        sliceHighlightLoading: true,
      };
      const ts = createTestStore(objectsReducer, mockEnv, state);
      ts.send({ tag: "proc-select", objectName: "w_new", procName: "of_new" }, (s) => {
        s.procedureDetail = null;
        s.wiringDiagram = null;
        s.wiringDiagramLoading = false;
        s.footprint = null;
        s.footprintLoading = false;
        s.sliceHighlight = null;
        s.sliceHighlightLoading = false;
      });
    });
  });

  describe("objects/footprint-load", () => {
    it("sets footprintLoading and fires getFootprint", () => {
      const ts = createTestStore(objectsReducer, mockEnv, initialObjectsState);
      ts.send({ tag: "footprint-load", objectName: "w_foo", procName: "of_bar" }, (s) => {
        s.footprintLoading = true;
      });
    });

    it("does nothing if already loaded for the same object/proc", () => {
      const loaded: FootprintResponse = { object: "w_foo", proc_name: "of_bar", kind: "sql", statements: [], blast_radius: [] };
      const state: ObjectsState = { ...initialObjectsState, footprint: loaded };
      const ts = createTestStore(objectsReducer, mockEnv, state);
      ts.send({ tag: "footprint-load", objectName: "w_foo", procName: "of_bar" }, () => {});
    });

    it("does nothing if a load is already in flight", () => {
      const state: ObjectsState = { ...initialObjectsState, footprintLoading: true };
      const ts = createTestStore(objectsReducer, mockEnv, state);
      ts.send({ tag: "footprint-load", objectName: "w_foo", procName: "of_bar" }, () => {});
    });
  });

  describe("objects/footprint-loaded", () => {
    it("stores the footprint and clears loading", () => {
      const data: FootprintResponse = {
        object: "w_foo",
        proc_name: "of_bar",
        kind: "sql",
        statements: [{
          stmt_key: "stmt:1",
          file: "w_foo.srw",
          line: 30,
          legs: [{ column: { namespace: null, table: "usrmembers", column: "koduser" }, leg_kind: "reads", leg_source: "sql_text" }],
        }],
        blast_radius: [],
      };
      const state: ObjectsState = { ...initialObjectsState, footprintLoading: true };
      const ts = createTestStore(objectsReducer, mockEnv, state);
      ts.send({ tag: "footprint-loaded", data }, (s) => {
        s.footprint = data;
        s.footprintLoading = false;
      });
    });
  });

  describe("objects/footprint-error", () => {
    it("stores the error and clears loading", () => {
      const state: ObjectsState = { ...initialObjectsState, footprintLoading: true };
      const ts = createTestStore(objectsReducer, mockEnv, state);
      ts.send({ tag: "footprint-error", error: "boom" }, (s) => {
        s.footprint = { error: "boom" };
        s.footprintLoading = false;
      });
    });
  });

  describe("objects/highlight-slice", () => {
    it("sets sliceHighlightLoading and clears any prior highlight", () => {
      const state: ObjectsState = {
        ...initialObjectsState,
        sliceHighlight: { error: "stale" },
      };
      const ts = createTestStore(objectsReducer, mockEnv, state);
      ts.send({ tag: "highlight-slice", object: "w_foo", proc: "of_bar", line: 12, direction: "backward" }, (s) => {
        s.sliceHighlightLoading = true;
        s.sliceHighlight = null;
      });
    });
  });

  describe("objects/highlight-slice-loaded", () => {
    it("stores the slice result tagged with object/proc and clears loading", () => {
      const data: SliceResult = {
        origin: { object: "w_foo", proc: "of_bar", line: 12, var: "ls_x" },
        direction: "backward",
        steps: [{ object: "w_foo", proc: "of_bar", line: 8, var: "ls_x", kind: "definition", text: "ls_x = 1" }],
        procedures_traversed: ["w_foo.of_bar"],
      };
      const state: ObjectsState = { ...initialObjectsState, sliceHighlightLoading: true };
      const ts = createTestStore(objectsReducer, mockEnv, state);
      ts.send({ tag: "highlight-slice-loaded", object: "w_foo", proc: "of_bar", data }, (s) => {
        s.sliceHighlight = { ...data, object: "w_foo", proc: "of_bar" };
        s.sliceHighlightLoading = false;
      });
    });
  });

  describe("objects/highlight-slice-error", () => {
    it("stores the error and clears loading", () => {
      const state: ObjectsState = { ...initialObjectsState, sliceHighlightLoading: true };
      const ts = createTestStore(objectsReducer, mockEnv, state);
      ts.send({ tag: "highlight-slice-error", error: "boom" }, (s) => {
        s.sliceHighlight = { error: "boom" };
        s.sliceHighlightLoading = false;
      });
    });
  });

  describe("objects/clear-slice-highlight", () => {
    it("clears the highlight and loading flag", () => {
      const state: ObjectsState = {
        ...initialObjectsState,
        sliceHighlight: { origin: { object: "w_foo", proc: "of_bar", line: 12, var: null }, direction: "backward", steps: [], procedures_traversed: [], object: "w_foo", proc: "of_bar" },
        sliceHighlightLoading: true,
      };
      const ts = createTestStore(objectsReducer, mockEnv, state);
      ts.send({ tag: "clear-slice-highlight" }, (s) => {
        s.sliceHighlight = null;
        s.sliceHighlightLoading = false;
      });
    });
  });
});
