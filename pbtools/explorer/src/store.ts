// store.ts — SolidJS createStore adapter wrapping the reducer.

import { createStore, reconcile } from "solid-js/store";
import type { AppState } from "./types/state.js";
import type { AppAction } from "./types/actions.js";
import type { Dispatch, GetState, Env, Effect } from "./core.js";

export interface Store {
  state: AppState;
  dispatch: Dispatch;
  getState: GetState;
}

type ReducerFn = (state: AppState, action: AppAction) => [AppState, Effect | null];

export function createStoreAdapter(
  init: AppState,
  reducerFn: ReducerFn,
  env: Env,
): Store {
  const [state, setState] = createStore<AppState>(init);

  function dispatch(action: AppAction): void {
    const [next, effect] = reducerFn(state as AppState, action);
    setState(reconcile(next));
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
