// features/navigation/url-sync.ts — URL synchronization (bootstrap only).
// URL pushes during navigation are handled by reducers via env.pushUrl().

import type { Route } from "./types.js";
import type { AppAction } from "../../app/actions.js";
import type { Dispatch } from "../../core/reducer.js";
import { parse } from "./routes.js";

// ── Initialize from URL ─────────────────────────────────────────────────────

function dispatchFromRoute(dispatch: Dispatch<AppAction>, route: Route): void {
  switch (route.view) {
    case "objectDetail":
      dispatch({ tag: "objects", action: { type: "select", name: route.name } });
      break;
    case "procedureDetail":
      dispatch({ tag: "objects",
                 action: { type: "proc-select", objectName: route.name, procName: route.proc } });
      break;
    case "dwDetail":
      dispatch({ tag: "datawindows", action: { type: "select", name: route.name } });
      break;
    default:
      dispatch({ tag: "nav", action: { type: "navigate", route } });
  }
}

export function initViewFromUrl(dispatch: Dispatch<AppAction>): void {
  dispatchFromRoute(dispatch, parse(window.location.pathname));
}

// ── Browser back/forward ────────────────────────────────────────────────────

export function setupPopstateHandler(dispatch: Dispatch<AppAction>): void {
  window.addEventListener("popstate", () => {
    dispatchFromRoute(dispatch, parse(window.location.pathname));
  });
}
