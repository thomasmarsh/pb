// features/navigation/reducer.ts — Navigation feature reducer.

import type { Reducer } from "../../core/reducer.js";
import type { NavState, NavigationAction } from "./types.js";
import { print } from "./routes.js";
import { Effect } from "../../core/effect.js";

export interface NavEnv {
  pushUrl(path: string): void;
}

function reduce(draft: NavState, action: NavigationAction, env: NavEnv): Effect<NavigationAction> | null {
  switch (action.type) {
  case "navigate":
    draft.route = action.route;
    env.pushUrl(print(action.route));
    return null;
  default:
    return null;
  }
}

export const navReducer: Reducer<NavState, NavigationAction, NavEnv> = reduce;
