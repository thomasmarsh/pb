// store.test.ts — Integration tests for SolidJS store + reconcile behavior.
// The reducer tests in core.test.ts don't catch Set reactivity bugs because
// they bypass createStore/reconcile. This file tests the real store.

import { describe, it, expect } from "vitest";
import { createStore, reconcile } from "solid-js/store";
import { initialState, reducer } from "../src/core.js";
import type { AppState } from "../src/types/state.js";
import type { AppAction } from "../src/types/actions.js";
import type { Env } from "../src/core.js";

const mockEnv: Env = {
  getStats:             () => ({ execute: async () => {} }),
  getObjects:           () => ({ execute: async () => {} }),
  getObject:            () => ({ execute: async () => {} }),
  getObjectSource:      () => ({ execute: async () => {} }),
  getAllObjects:         () => ({ execute: async () => {} }),
  getProcedure:         () => ({ execute: async () => {} }),
  search:               () => ({ execute: async () => {} }),
  getDW:                () => ({ execute: async () => {} }),
  getDiagram:           () => ({ execute: async () => {} }),
  getQueries:           () => ({ execute: async () => {} }),
  runQuery:             () => ({ execute: async () => {} }),
  getExploreTree:       () => ({ execute: async () => {} }),
  getExploreProcedure:  () => ({ execute: async () => {} }),
  getExploreDatawindow: () => ({ execute: async () => {} }),
};

function createLiveStore() {
  const [state, setState] = createStore<AppState>(initialState());

  function dispatch(action: AppAction): void {
    const [next] = reducer(state as AppState, action, mockEnv);
    setState(reconcile(next));
  }

  return { state: state as AppState, dispatch };
}

describe("Store Set reactivity", () => {
  it("EXPLORE_TOGGLE adds node and is visible via .has()", () => {
    const store = createLiveStore();
    expect(store.state.explore.expandedNodes.has("lib:foo")).toBe(false);

    store.dispatch({ type: "EXPLORE_TOGGLE", nodeId: "lib:foo" });

    // This is the key assertion — does the live store reflect the toggle?
    expect(store.state.explore.expandedNodes.has("lib:foo")).toBe(true);
  });

  it("EXPLORE_TOGGLE removes node when already expanded", () => {
    const store = createLiveStore();
    store.dispatch({ type: "EXPLORE_TOGGLE", nodeId: "lib:foo" });
    expect(store.state.explore.expandedNodes.has("lib:foo")).toBe(true);

    store.dispatch({ type: "EXPLORE_TOGGLE", nodeId: "lib:foo" });
    expect(store.state.explore.expandedNodes.has("lib:foo")).toBe(false);
  });

  it("EXPLORE_EXPAND_ALL populates all library and object nodes", () => {
    const store = createLiveStore();
    store.dispatch({
      type: "EXPLORE_LOADED",
      data: {
        libraries: [{
          name: "lib1.pbl",
          objects: [
            { name: "obj1", kind: "powerscript", file: "f", procedures: [] },
            { name: "obj2", kind: "datawindow", file: "f", procedures: [] },
          ],
        }],
      },
    });

    store.dispatch({ type: "EXPLORE_EXPAND_ALL" });

    expect(store.state.explore.expandedNodes.has("lib:lib1.pbl")).toBe(true);
    expect(store.state.explore.expandedNodes.has("obj:lib1.pbl:obj1")).toBe(true);
    expect(store.state.explore.expandedNodes.has("obj:lib1.pbl:obj2")).toBe(true);
  });

  it("EXPLORE_COLLAPSE_ALL clears all expanded nodes", () => {
    const store = createLiveStore();
    store.dispatch({ type: "EXPLORE_TOGGLE", nodeId: "lib:foo" });
    store.dispatch({ type: "EXPLORE_TOGGLE", nodeId: "lib:bar" });
    expect(store.state.explore.expandedNodes.size).toBe(2);

    store.dispatch({ type: "EXPLORE_COLLAPSE_ALL" });
    expect(store.state.explore.expandedNodes.size).toBe(0);
  });

  it("multiple toggles accumulate correctly", () => {
    const store = createLiveStore();
    store.dispatch({ type: "EXPLORE_TOGGLE", nodeId: "lib:a" });
    store.dispatch({ type: "EXPLORE_TOGGLE", nodeId: "lib:b" });
    store.dispatch({ type: "EXPLORE_TOGGLE", nodeId: "lib:c" });

    expect(store.state.explore.expandedNodes.has("lib:a")).toBe(true);
    expect(store.state.explore.expandedNodes.has("lib:b")).toBe(true);
    expect(store.state.explore.expandedNodes.has("lib:c")).toBe(true);
    expect(store.state.explore.expandedNodes.size).toBe(3);
  });

  it("EXPLORE_TOGGLE with treeFilter preserves filter", () => {
    const store = createLiveStore();
    store.dispatch({ type: "EXPLORE_FILTER", q: "foo" });
    store.dispatch({ type: "EXPLORE_TOGGLE", nodeId: "lib:foo" });

    expect(store.state.explore.treeFilter).toBe("foo");
    expect(store.state.explore.expandedNodes.has("lib:foo")).toBe(true);
  });

  it("EXPLORE_TOGGLE does not affect other expanded nodes", () => {
    const store = createLiveStore();
    store.dispatch({ type: "EXPLORE_TOGGLE", nodeId: "lib:a" });
    store.dispatch({ type: "EXPLORE_TOGGLE", nodeId: "lib:b" });
    store.dispatch({ type: "EXPLORE_TOGGLE", nodeId: "lib:a" });

    expect(store.state.explore.expandedNodes.has("lib:a")).toBe(false);
    expect(store.state.explore.expandedNodes.has("lib:b")).toBe(true);
    expect(store.state.explore.expandedNodes.size).toBe(1);
  });

  it("reactive getter tracks Set changes after reconcile", () => {
    const [state, setState] = createStore<AppState>(initialState());
    const expanded = () => (state as AppState).explore.expandedNodes;

    // Initial: empty set
    expect(expanded().has("lib:foo")).toBe(false);

    // Dispatch toggle via reducer + reconcile
    const [next] = reducer(state as AppState, { type: "EXPLORE_TOGGLE", nodeId: "lib:foo" }, mockEnv);
    setState(reconcile(next));

    // After reconcile: must reflect the toggle
    expect(expanded().has("lib:foo")).toBe(true);

    // Toggle off
    const [next2] = reducer(state as AppState, { type: "EXPLORE_TOGGLE", nodeId: "lib:foo" }, mockEnv);
    setState(reconcile(next2));
    expect(expanded().has("lib:foo")).toBe(false);
  });
});
