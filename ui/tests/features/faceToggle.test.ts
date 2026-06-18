// tests/features/faceToggle.test.ts — Reducer tests for face/scroll state logic.

import { describe, it } from "vitest";
import { Effect } from "../../src/core/effect.js";
import { createTestStore } from "../test-store.js";
import { objectsReducer, initialObjectsState, type ObjectsEnv } from "../../src/features/objects/reducer.js";
import { datawindowsReducer, initialDatawindowsState, type DatawindowsEnv } from "../../src/features/datawindows/reducer.js";
import { tablesReducer, initialTablesState, type TablesEnv } from "../../src/features/tables/reducer.js";
import type { ObjectsState } from "../../src/features/objects/types.js";
import type { DatawindowsState } from "../../src/features/datawindows/types.js";

const objEnv: ObjectsEnv = {
  getObjects: () => Effect.none(),
  getAllObjects: () => Effect.none(),
  getObject: () => Effect.none(),
  getObjectSource: () => Effect.none(),
  getProcedure: () => Effect.none(),
  navigate: () => Effect.none(),
};

const dwEnv: DatawindowsEnv = {
  getObjects: () => Effect.none(),
  getDW: () => Effect.none(),
  navigate: () => Effect.none(),
};

const tabEnv: TablesEnv = {
  getTables: () => Effect.none(),
  getTableDetail: () => Effect.none(),
  navigate: () => Effect.none(),
};

// ── Object face/scroll ────────────────────────────────────────────────────────

describe("objects face/scroll state", () => {
  it("set-object-face source→analysis saves source scroll and switches face", () => {
    const ts = createTestStore(objectsReducer, objEnv, initialObjectsState);
    ts.send({ type: "set-object-face", name: "w_payment", face: "analysis", scrollTop: 120 }, (s) => {
      s.objectFace = "analysis";
      s.objectScrollPos["w_payment"] = { source: 120, analysis: 0 };
    });
  });

  it("set-object-face analysis→source saves analysis scroll and switches face", () => {
    const initial: ObjectsState = { ...initialObjectsState, objectFace: "analysis" };
    const ts = createTestStore(objectsReducer, objEnv, initial);
    ts.send({ type: "set-object-face", name: "w_payment", face: "source", scrollTop: 300 }, (s) => {
      s.objectFace = "source";
      s.objectScrollPos["w_payment"] = { source: 0, analysis: 300 };
    });
  });

  it("set-object-face stores scroll per entity name (no cross-contamination)", () => {
    const ts = createTestStore(objectsReducer, objEnv, initialObjectsState);
    // Toggle w_payment source→analysis; saves source scroll under w_payment only.
    ts.send({ type: "set-object-face", name: "w_payment", face: "analysis", scrollTop: 50 }, (s) => {
      s.objectFace = "analysis";
      s.objectScrollPos["w_payment"] = { source: 50, analysis: 0 };
      // w_admin not present in scrollPos → no contamination yet
    });
    // Now toggle analysis→source (face is "analysis" from above); saves analysis scroll for w_admin.
    ts.send({ type: "set-object-face", name: "w_admin", face: "source", scrollTop: 200 }, (s) => {
      s.objectFace = "source";
      s.objectScrollPos["w_admin"] = { source: 0, analysis: 200 };
      // w_payment scroll entry unchanged: { source: 50, analysis: 0 }
    });
  });

  it("set-object-face preserves existing analysis scroll on re-toggle to source", () => {
    const initial: ObjectsState = {
      ...initialObjectsState,
      objectFace: "analysis",
      objectScrollPos: { "w_payment": { source: 80, analysis: 0 } },
    };
    const ts = createTestStore(objectsReducer, objEnv, initial);
    ts.send({ type: "set-object-face", name: "w_payment", face: "source", scrollTop: 150 }, (s) => {
      s.objectFace = "source";
      s.objectScrollPos["w_payment"] = { source: 80, analysis: 150 };
    });
  });
});

// ── Proc face/scroll ──────────────────────────────────────────────────────────

describe("proc face/scroll state", () => {
  it("set-proc-face stores scroll keyed by object:proc", () => {
    const ts = createTestStore(objectsReducer, objEnv, initialObjectsState);
    ts.send({ type: "set-proc-face", key: "w_payment:f_process", face: "analysis", scrollTop: 60 }, (s) => {
      s.procFace = "analysis";
      s.procScrollPos["w_payment:f_process"] = { source: 60, analysis: 0 };
    });
  });

  it("set-proc-face second entity does not overwrite first", () => {
    const ts = createTestStore(objectsReducer, objEnv, initialObjectsState);
    // Toggle first proc source→analysis at scroll 60.
    ts.send({ type: "set-proc-face", key: "w_payment:f_process", face: "analysis", scrollTop: 60 }, (s) => {
      s.procFace = "analysis";
      s.procScrollPos["w_payment:f_process"] = { source: 60, analysis: 0 };
    });
    // Toggle second proc analysis→source (face is "analysis" from above); first entry unchanged.
    ts.send({ type: "set-proc-face", key: "w_admin:f_validate", face: "source", scrollTop: 90 }, (s) => {
      s.procFace = "source";
      s.procScrollPos["w_admin:f_validate"] = { source: 0, analysis: 90 };
      // w_payment:f_process entry is still { source: 60, analysis: 0 }
    });
  });
});

// ── DataWindow face/scroll ────────────────────────────────────────────────────

describe("datawindows face/scroll state", () => {
  it("set-dw-face source→analysis saves scroll and switches face", () => {
    const ts = createTestStore(datawindowsReducer, dwEnv, initialDatawindowsState);
    ts.send({ type: "set-dw-face", name: "d_payment_grid", face: "analysis", scrollTop: 40 }, (s) => {
      s.dwFace = "analysis";
      s.dwScrollPos["d_payment_grid"] = { source: 40, analysis: 0 };
    });
  });

  it("set-dw-face restores stored scroll on toggle back", () => {
    const initial: DatawindowsState = {
      ...initialDatawindowsState,
      dwFace: "analysis",
      dwScrollPos: { "d_payment_grid": { source: 100, analysis: 0 } },
    };
    const ts = createTestStore(datawindowsReducer, dwEnv, initial);
    ts.send({ type: "set-dw-face", name: "d_payment_grid", face: "source", scrollTop: 250 }, (s) => {
      s.dwFace = "source";
      s.dwScrollPos["d_payment_grid"] = { source: 100, analysis: 250 };
    });
  });
});

// ── Table face/scroll ─────────────────────────────────────────────────────────

describe("tables face/scroll state", () => {
  it("set-table-face source→analysis saves scroll and switches face", () => {
    const ts = createTestStore(tablesReducer, tabEnv, initialTablesState);
    ts.send({ type: "set-table-face", name: "accounts", face: "analysis", scrollTop: 70 }, (s) => {
      s.tableFace = "analysis";
      s.tableScrollPos["accounts"] = { source: 70, analysis: 0 };
    });
  });

  it("set-table-face stores scroll per table name (no cross-contamination)", () => {
    const ts = createTestStore(tablesReducer, tabEnv, initialTablesState);
    // Toggle accounts source→analysis.
    ts.send({ type: "set-table-face", name: "accounts", face: "analysis", scrollTop: 10 }, (s) => {
      s.tableFace = "analysis";
      s.tableScrollPos["accounts"] = { source: 10, analysis: 0 };
    });
    // Toggle customers analysis→source (face is "analysis" from above); accounts unchanged.
    ts.send({ type: "set-table-face", name: "customers", face: "source", scrollTop: 20 }, (s) => {
      s.tableFace = "source";
      s.tableScrollPos["customers"] = { source: 0, analysis: 20 };
    });
  });
});
