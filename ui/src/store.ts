// store.ts — SolidJS createStore adapter wrapping the reducer.
// Syncs URL via pushState after view-changing actions.

import { createStore, reconcile } from "solid-js/store";
import type { AppState } from "./types/state.js";
import type { AppAction } from "./types/actions.js";
import type { Dispatch, Env, Reducer } from "./core.js";
import { syncUrlFromState } from "./navigation.js";

export interface Store {
  state: AppState;
  dispatch: Dispatch;
}

// Actions that change the view — sync URL after these
const VIEW_ACTIONS = new Set([
  "NAVIGATE", "OBJECT_SELECTED", "PROCEDURE_SELECTED", "DW_SELECTED",
]);

export function createStoreAdapter(
  init: AppState,
  reducerFn: Reducer,
  env: Env,
): Store {
  const [state, setState] = createStore<AppState>(init);

  function dispatch(action: AppAction): void {
    const [next, effect] = reducerFn(state as AppState, action, env);
    setState(reconcile(next));

    if (VIEW_ACTIONS.has(action.type)) {
      syncUrlFromState(next.view, {
        objectDetail: next.objectDetail,
        procedureDetail: next.procedureDetail,
        dwDetail: next.dwDetail,
      }, action);
    }

    if (effect) {
      effect.execute(dispatch).catch(e => console.error("unhandled effect error:", e));
    }
  }

  return { state, dispatch };
}
