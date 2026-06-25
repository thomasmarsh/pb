// features/navigation/url-sync.ts — URL synchronization (bootstrap only).
// URL pushes during navigation are handled by reducers via env.pushUrl().

import type { Route } from "@pb/platform";
import type { AppAction } from "../../features/app/actions.js";
import type { Dispatch } from "@pb/core";
import { parse } from "@pb/platform";

// ── Initialize from URL ─────────────────────────────────────────────────────

function dispatchFromRoute(dispatch: Dispatch<AppAction>, route: Route): void {
  switch (route.view) {
    case "objectDetail":
      dispatch({ tag: "objects", action: { tag: "select", name: route.name } });
      break;
    case "procedureDetail":
      dispatch({ tag: "objects",
                 action: { tag: "proc-select", objectName: route.name, procName: route.proc } });
      break;
    case "dwDetail":
      dispatch({ tag: "datawindows", action: { tag: "select", name: route.name } });
      break;
    case "tableDetail":
      dispatch({ tag: "tables", action: { tag: "select", name: route.name } });
      break;
    case "queries":
      dispatch({ tag: "nav", action: { tag: "navigate", route } });
      if (route.sqlText) {
        dispatch({ tag: "queries", action: { tag: "run-sql", sql: route.sqlText } });
      } else if (route.queryName) {
        dispatch({ tag: "queries", action: { tag: "restore", name: route.queryName, params: route.queryParams ?? {} } });
      }
      break;
    default:
      dispatch({ tag: "nav", action: { tag: "navigate", route } });
  }
}

export function initViewFromUrl(dispatch: Dispatch<AppAction>): void {
  dispatchFromRoute(dispatch, parse(window.location.pathname, window.location.search));
}

// ── Browser back/forward ────────────────────────────────────────────────────

export function setupPopstateHandler(dispatch: Dispatch<AppAction>): void {
  window.addEventListener("popstate", () => {
    dispatchFromRoute(dispatch, parse(window.location.pathname, window.location.search));
  });
}
