// store.ts — SolidJS createStore adapter wrapping the reducer.
// Syncs URL via pushState after view-changing actions.

import { createStore, reconcile } from "solid-js/store";
import type { AppState } from "./types/state.js";
import type { AppAction } from "./types/actions.js";
import type { Dispatch, GetState, Env, Effect } from "./core.js";
import { syncUrlFromState } from "./navigation.js";

export interface Store {
  state: AppState;
  dispatch: Dispatch;
  getState: GetState;
}

type ReducerFn = (state: AppState, action: AppAction) => [AppState, Effect | null];

// Actions that change the view — sync URL after these
const VIEW_ACTIONS = new Set([
  "NAVIGATE", "OBJECT_SELECTED", "PROCEDURE_SELECTED", "DW_SELECTED",
]);

export function createStoreAdapter(
  init: AppState,
  reducerFn: ReducerFn,
  env: Env,
): Store {
  const [state, setState] = createStore<AppState>(init);

  function dispatch(action: AppAction): void {
    const [next, effect] = reducerFn(state as AppState, action);
    setState(reconcile(next));

    // Sync URL after view-changing actions
    if (VIEW_ACTIONS.has(action.type)) {
      syncUrlFromState(next.view, {
        objectDetail: next.objectDetail,
        procedureDetail: next.procedureDetail,
        dwDetail: next.dwDetail,
      }, action);
    }

    if (effect) {
      effect(dispatch, () => state as AppState, env);
    }
  }

  return {
    state,
    dispatch,
    getState: () => state as AppState,
  };
}
