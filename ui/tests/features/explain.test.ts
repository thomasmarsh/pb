// tests/features/explain.test.ts — Tests for the app-level "explain" reducer
// case (Plan 222 Phase 3): a plain keyed fetch, no job-poll, mirroring
// cfgDiagram's `${object}::${proc}` keying without the job-poll machinery.

import { describe, it, expect } from "vitest";
import { Effect } from "@pb/core";
import { createTestStore } from "../test-store.js";
import { reducer, initialState, type AppEnv } from "../../app/src/reducer.js";
import type { ExplainPseudocodeResponse } from "@pb/platform";
import { mockEnv } from "../helpers.js";

const PSEUDOCODE: ExplainPseudocodeResponse = {
  declaredSig: null,
  rootRegion: "region_0",
  rootSig: { inputs: [], outputs: [], effects: [] },
  regions: {
    region_0: [
      { tag: "PReturn", contents: [null, 1], stmtText: "return true" },
    ],
  },
  sourceOriginal: "return true",
  procStartLine: 1,
};

describe("explain reducer", () => {
  it("fires getExplainPseudocode and stores the result on loaded", () => {
    const env: AppEnv = { ...mockEnv, getExplainPseudocode: () => Effect.send(PSEUDOCODE) };
    const ts = createTestStore(reducer, env, initialState());

    ts.send(
      { tag: "explain", action: { tag: "request", key: "w_obj::uf_save", object: "w_obj", proc: "uf_save" } },
      (s) => {
        s.explainPseudocodes["w_obj::uf_save"] = { object: "w_obj", proc: "uf_save", data: null };
      },
    );
    ts.receive(
      { tag: "explain", action: { tag: "loaded", key: "w_obj::uf_save", data: PSEUDOCODE } },
      (s) => {
        s.explainPseudocodes["w_obj::uf_save"]!.data = PSEUDOCODE;
      },
    );

    ts.assertDrained();
  });

  it("is a no-op while a fetch for the same key is already in flight", () => {
    const state = {
      ...initialState(),
      explainPseudocodes: {
        "w_obj::uf_save": { object: "w_obj", proc: "uf_save", data: null },
      },
    };
    const ts = createTestStore(reducer, mockEnv, state);
    ts.send(
      { tag: "explain", action: { tag: "request", key: "w_obj::uf_save", object: "w_obj", proc: "uf_save" } },
      () => {},
    );
  });

  it("stores the error message on the keyed entry when the fetch fails", async () => {
    const env: AppEnv = {
      ...mockEnv,
      getExplainPseudocode: () => Effect.fromPromise(() => Promise.reject(new Error("API 404"))),
    };
    const ts = createTestStore(reducer, env, initialState());

    ts.send(
      { tag: "explain", action: { tag: "request", key: "w_obj::uf_missing", object: "w_obj", proc: "uf_missing" } },
      (s) => {
        s.explainPseudocodes["w_obj::uf_missing"] = { object: "w_obj", proc: "uf_missing", data: null };
      },
    );

    await ts.drain();

    ts.receive(
      { tag: "explain", action: { tag: "failed", key: "w_obj::uf_missing", error: "Error: API 404" } },
      (s) => {
        s.explainPseudocodes["w_obj::uf_missing"]!.data = { error: "Error: API 404" };
      },
    );

    expect(ts.getState().explainPseudocodes["w_obj::uf_missing"]?.data).toEqual({ error: "Error: API 404" });
    ts.assertDrained();
  });
});
