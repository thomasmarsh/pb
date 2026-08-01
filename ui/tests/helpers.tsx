// tests/helpers.tsx — Shared test utilities for component tests.

import { type JSX } from "solid-js";
import { render, cleanup } from "@solidjs/testing-library";
import { afterEach } from "vitest";
import { Effect, createStore, type Store } from "@pb/core";
import { initialState, reducer } from "../app/src/reducer.js";
import type { AppState } from "../app/src/state.js";
import type { AppAction } from "../app/src/actions.js";
import type { AppEnv } from "../app/src/reducer.js";

// ── Mock environment ──────────────────────────────────────────────────────────

export const mockEnv: AppEnv = {
  getStats: () => Effect.none(),
  getCodeQualityReport: () => Effect.none(),
  getSqlLintSummary: () => Effect.none(),
  getObjects: () => Effect.none(),
  getObject: () => Effect.none(),
  getObjectSource: () => Effect.none(),
  getAllObjects: () => Effect.none(),
  getProcedure: () => Effect.none(),
  getProcedures: () => Effect.none(),
  getWiringDiagram: () => Effect.none(),
  getFootprint: () => Effect.none(),
  getSlice: () => Effect.none(),
  search: () => Effect.none(),
  getDW: () => Effect.none(),
  getDwLayout: () => Effect.none(),
  getObjectAst: () => Effect.none(),
  getObjectLayout: () => Effect.none(),
  submitDiagramJob: () => Effect.none(),
  pollDiagramJob: () => Effect.none(),
  submitCfgDiagramJob: () => Effect.none(),
  pollCfgDiagramJob: () => Effect.none(),
  getExplainPseudocode: () => Effect.none(),
  getQueries: () => Effect.none(),
  runQuery: () => Effect.none(),
  runSql: () => Effect.none(),
  getExploreTree: () => Effect.none(),
  getExploreProcedure: () => Effect.none(),
  getExploreDatawindow: () => Effect.none(),
  getSchemas: () => Effect.none(),
  getTables: () => Effect.none(),
  getTableDetail: () => Effect.none(),
  getColumnUsage: () => Effect.none(),
  getDecompositionCandidates: () => Effect.none(),
  getDiagnostics: () => Effect.none(),
  getDiagnosticsTimeline: (_z: number) => Effect.none(),
  getTypeCoverage: () => Effect.none(),
  getLiveProcedures: () => Effect.none(),
  getDeadVars: () => Effect.none(),
  getTypeMismatches: () => Effect.none(),
  getCapabilities: () => Effect.none(),
  getCapabilityProcedures: () => Effect.none(),
  getDwQueries: () => Effect.none(),
  executeSql: () => Effect.none(),
  navigate: () => Effect.none(),
  pushUrl: () => {},
  loadTheme: () => Effect.send("dark"),
  applyTheme: () => Effect.none(),
};

// ── Store + action capture ────────────────────────────────────────────────────

export interface TestStoreResult {
  store: Store<AppState, AppAction>;
  captured: AppAction[];
}

export function createTestStore(
  overrides?: Partial<AppState>,
): TestStoreResult {
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
