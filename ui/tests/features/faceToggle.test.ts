// tests/features/faceToggle.test.ts — Reducer tests for face/scroll state logic.

import { describe, it } from "vitest";
import { Effect } from "../../src/core/effect.js";
import { createTestStore } from "../test-store.js";
import { datawindowsReducer, initialDatawindowsState, type DatawindowsEnv } from "../../src/features/datawindows/reducer.js";
import { tablesReducer, initialTablesState, type TablesEnv } from "../../src/features/tables/reducer.js";
import type { DatawindowsState } from "../../src/features/datawindows/types.js";

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

// ── DataWindow face/scroll ────────────────────────────────────────────────────

describe("datawindows face/scroll state", () => {
  it("set-dw-face source→analysis saves scroll and switches face", () => {
    const ts = createTestStore(datawindowsReducer, dwEnv, initialDatawindowsState);
    ts.send({ tag: "set-dw-face", name: "d_payment_grid", face: "analysis", scrollTop: 40 }, (s) => {
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
    ts.send({ tag: "set-dw-face", name: "d_payment_grid", face: "source", scrollTop: 250 }, (s) => {
      s.dwFace = "source";
      s.dwScrollPos["d_payment_grid"] = { source: 100, analysis: 250 };
    });
  });
});

// ── Table face/scroll ─────────────────────────────────────────────────────────

describe("tables face/scroll state", () => {
  it("set-table-face source→analysis saves scroll and switches face", () => {
    const ts = createTestStore(tablesReducer, tabEnv, initialTablesState);
    ts.send({ tag: "set-table-face", name: "accounts", face: "analysis", scrollTop: 70 }, (s) => {
      s.tableFace = "analysis";
      s.tableScrollPos["accounts"] = { source: 70, analysis: 0 };
    });
  });

  it("set-table-face stores scroll per table name (no cross-contamination)", () => {
    const ts = createTestStore(tablesReducer, tabEnv, initialTablesState);
    // Toggle accounts source→analysis.
    ts.send({ tag: "set-table-face", name: "accounts", face: "analysis", scrollTop: 10 }, (s) => {
      s.tableFace = "analysis";
      s.tableScrollPos["accounts"] = { source: 10, analysis: 0 };
    });
    // Toggle customers analysis→source (face is "analysis" from above); accounts unchanged.
    ts.send({ tag: "set-table-face", name: "customers", face: "source", scrollTop: 20 }, (s) => {
      s.tableFace = "source";
      s.tableScrollPos["customers"] = { source: 0, analysis: 20 };
    });
  });
});
