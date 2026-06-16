// tests/helpers.tsx — Shared test utilities for component tests.

import { type ParentProps, type JSX } from "solid-js";
import { render, cleanup } from "@solidjs/testing-library";
import { afterEach } from "vitest";
import { Effect } from "../src/core/effect.js";
import { createStore } from "../src/core/store.js";
import { initialState, reducer } from "../src/app/reducer.js";
import type { AppState } from "../src/app/state.js";
import type { AppAction } from "../src/app/actions.js";
import type { Store } from "../src/core/store.js";
import type { AppEnv } from "../src/app/reducer.js";

// ── Mock environment ──────────────────────────────────────────────────────────

export const mockEnv: AppEnv = {
  getStats: () => Effect.none(),
  getObjects: () => Effect.none(),
  getObject: () => Effect.none(),
  getObjectSource: () => Effect.none(),
  getAllObjects: () => Effect.none(),
  getProcedure: () => Effect.none(),
  search: () => Effect.none(),
  getDW: () => Effect.none(),
  getDiagram: () => Effect.none(),
  getQueries: () => Effect.none(),
  runQuery: () => Effect.none(),
  getExploreTree: () => Effect.none(),
  getExploreProcedure: () => Effect.none(),
  getExploreDatawindow: () => Effect.none(),
  getTables: () => Effect.none(),
  getTableDetail: () => Effect.none(),
  navigate: () => Effect.none(),
  pushUrl: () => {},
};

// ── Store + action capture ────────────────────────────────────────────────────

export interface TestStoreResult {
  store: Store<AppState, AppAction>;
  captured: AppAction[];
}

export function createTestStore(overrides?: Partial<AppState>): TestStoreResult {
  const captured: AppAction[] = [];
  const init = { ...initialState(), ...overrides };
  const store = createStore(init, reducer, mockEnv, (action) => {
    captured.push(action);
  });
  return { store, captured };
}

// ── Render with store ─────────────────────────────────────────────────────────

export interface RenderResult {
  store: Store<AppState, AppAction>;
  captured: AppAction[];
  unmount: () => void;
  container: HTMLElement;
}

/**
 * Render a component that takes { store } props.
 * Returns the testing-library queries + captured actions.
 */
export function renderWithStore(
  Component: (props: { store: Store<AppState, AppAction> }) => JSX.Element,
  overrides?: Partial<AppState>,
): RenderResult {
  const { store, captured } = createTestStore(overrides);
  const result = render(() => <Component store={store} />);
  return {
    store,
    captured,
    unmount: result.unmount,
    container: result.container,
  };
}

// ── Cleanup ───────────────────────────────────────────────────────────────────

afterEach(() => {
  cleanup();
});
