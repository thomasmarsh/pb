// features/navigation/reducer.ts — Navigation feature reducer.

import type { Reducer } from "../../core/reducer.js";
import type { NavState, NavigationAction, BreadcrumbSegment } from "./types.js";
import { print } from "./routes.js";
import { crumbsForRoute, ICONS } from "./breadcrumb.js";
import { Effect } from "../../core/effect.js";

export interface NavEnv {
  pushUrl(path: string): void;
}

function reduce(draft: NavState, action: NavigationAction, env: NavEnv): Effect<NavigationAction> | null {
  switch (action.tag) {
  case "navigate": {
    draft.route = action.route;
    draft.crumbs = crumbsForRoute(action.route);
    draft.askContext = null;
    const prevHistory = draft.history.slice(0, draft.historyIdx + 1);
    draft.history = [...prevHistory, action.route];
    draft.historyIdx = draft.history.length - 1;
    env.pushUrl(print(action.route));
    return null;
  }
  case "navigate-from-ask": {
    draft.route = action.route;
    draft.askContext = { queryName: action.queryName, queryRoute: action.queryRoute };
    const askCrumb: BreadcrumbSegment = { icon: ICONS.ask, label: action.queryName, route: action.queryRoute };
    const entityCrumbs = crumbsForRoute(action.route);
    // drop the leading list crumb (e.g. "Objects") so the chain reads: Ask › entity
    const trimmed = entityCrumbs[0]?.icon === ICONS.list ? entityCrumbs.slice(1) : entityCrumbs;
    draft.crumbs = [askCrumb, ...trimmed];
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
      draft.askContext = null;
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
      draft.askContext = null;
      env.pushUrl(print(route));
    }
    return null;
  }
  default:
    return null;
  }
}

export const navReducer: Reducer<NavState, NavigationAction, NavEnv> = reduce;
