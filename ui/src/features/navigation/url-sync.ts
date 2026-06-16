// features/navigation/url-sync.ts — URL synchronization (bootstrap only).
// URL pushes during navigation are handled by reducers via env.pushUrl().

import type { ViewName } from "./types.js";
import type { AppAction } from "../../app/actions.js";
import type { Dispatch } from "../../core/reducer.js";
import { pathToView } from "./routes.js";

// ── Initialize from URL ─────────────────────────────────────────────────────

function dispatchFromResolved(dispatch: Dispatch<AppAction>, view: ViewName, params: Record<string, string>): void {
  if (view === "objectDetail" && params.objectName) {
    dispatch({ tag: "objects", action: { type: "select", name: params.objectName } });
  } else if (view === "procedureDetail" && params.procObject && params.procName) {
    dispatch({ tag: "objects", action: { type: "proc-select", objectName: params.procObject, procName: params.procName } });
  } else if (view === "dwDetail" && params.dwName) {
    dispatch({ tag: "datawindows", action: { type: "select", name: params.dwName } });
  } else {
    dispatch({ tag: "nav", action: { type: "navigate", view } });
  }
}

export function initViewFromUrl(dispatch: Dispatch<AppAction>): void {
  const { view, params } = pathToView(window.location.pathname);
  dispatchFromResolved(dispatch, view, params);
}

// ── Browser back/forward ────────────────────────────────────────────────────

export function setupPopstateHandler(dispatch: Dispatch<AppAction>): void {
  window.addEventListener("popstate", () => {
    const { view, params } = pathToView(window.location.pathname);
    dispatchFromResolved(dispatch, view, params);
  });
}
