// features/navigation/reducer.ts — Navigation feature reducer.

import type { Reducer } from "../../core/reducer.js";
import type { NavState, NavigationAction } from "./types.js";
import { print } from "./routes.js";
import { crumbsForRoute } from "./breadcrumb.js";
import { Effect } from "../../core/effect.js";

export interface NavEnv {
  pushUrl(path: string): void;
}

function reduce(draft: NavState, action: NavigationAction, env: NavEnv): Effect<NavigationAction> | null {
  switch (action.type) {
  case "navigate": {
    draft.route = action.route;
    draft.crumbs = crumbsForRoute(action.route);
    // Truncate any forward history when navigating to a new destination.
    const prevHistory = draft.history.slice(0, draft.historyIdx + 1);
    draft.history = [...prevHistory, action.route];
    draft.historyIdx = draft.history.length - 1;
    env.pushUrl(print(action.route));
    return null;
  }
  case "back": {
    if (draft.historyIdx > 0) {
      draft.historyIdx -= 1;
      const route = draft.history[draft.historyIdx]!;
      draft.route = route;
      draft.crumbs = crumbsForRoute(route);
      env.pushUrl(print(route));
    }
    return null;
  }
  case "forward": {
    if (draft.historyIdx < draft.history.length - 1) {
      draft.historyIdx += 1;
      const route = draft.history[draft.historyIdx]!;
      draft.route = route;
      draft.crumbs = crumbsForRoute(route);
      env.pushUrl(print(route));
    }
    return null;
  }
  default:
    return null;
  }
}

export const navReducer: Reducer<NavState, NavigationAction, NavEnv> = reduce;
