// features/navigation/reducer.ts — Navigation feature reducer.

import type { Reducer } from "../../core/reducer.js";
import type { NavState, NavigationAction } from "./types.js";
import { VIEW_PREFIX } from "./routes.js";
import { Effect } from "../../core/effect.js";

export interface NavEnv {
  pushUrl(path: string): void;
}

function reduce(draft: NavState, action: NavigationAction, env: NavEnv): Effect<NavigationAction> | null {
  switch (action.type) {
  case "navigate":
    draft.view = action.view;
    env.pushUrl(VIEW_PREFIX[action.view] ?? "/");
    return null;
  default:
    return null;
  }
}

export const navReducer: Reducer<NavState, NavigationAction, NavEnv> = reduce;
