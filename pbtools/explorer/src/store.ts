// store.ts — Typed store with dispatch, subscribe, getState.

import type { AppState } from "./types/state.js";
import type { AppAction } from "./types/actions.js";
import type { Dispatch, GetState, Env } from "./core.js";

export interface Store {
  getState: GetState;
  dispatch: Dispatch;
  subscribe(fn: (state: AppState) => void): () => boolean;
}

export function createStore(
  initialState: AppState,
  reducerFn: (state: AppState, action: AppAction) => [AppState, ((dispatch: Dispatch, getState: GetState, env: Env) => Promise<void>) | null],
  env: Env,
): Store {
  let state = initialState;
  const listeners = new Set<(state: AppState) => void>();

  function dispatch(action: AppAction): void {
    const [next, effect] = reducerFn(state, action);
    state = next;
    for (const fn of listeners) fn(state);
    if (effect) {
      effect(dispatch, () => state, env);
    }
  }

  return {
    getState: () => state,
    dispatch,
    subscribe(fn) {
      listeners.add(fn);
      return () => listeners.delete(fn);
    },
  };
}
