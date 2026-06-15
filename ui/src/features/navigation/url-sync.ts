// features/navigation/url-sync.ts — URL synchronization.

import type { ViewName, NavigationAction } from "./types.js";
import type { Dispatch } from "../../core/reducer.js";
import { viewToPath, pathToView } from "./routes.js";

/** Action types that require a URL push after dispatch. */
export const NAV_SYNC_ACTIONS = new Set(["navigate", "object-selected", "procedure-selected", "dw-selected"]);

// ── Store → URL sync ────────────────────────────────────────────────────────

export function syncUrlFromState(
  view: ViewName,
  state: Record<string, unknown>,
  action?: NavigationAction,
): void {
  let path: string;

  if (action?.type === "procedure-selected" && typeof action.objectName === "string" && typeof action.procName === "string") {
    path = `/objects/${encodeURIComponent(action.objectName)}/${encodeURIComponent(action.procName)}`;
  } else if (action?.type === "object-selected" && typeof action.name === "string") {
    path = `/objects/${encodeURIComponent(action.name)}`;
  } else if (action?.type === "dw-selected" && typeof action.name === "string") {
    path = `/datawindows/${encodeURIComponent(action.name)}`;
  } else {
    path = viewToPath(view, state);
  }

  const current = window.location.pathname + window.location.search;
  if (path !== current) {
    history.pushState({ view }, "", path);
  }
}

// ── Initialize from URL ─────────────────────────────────────────────────────

function dispatchFromResolved(dispatch: Dispatch<NavigationAction>, view: ViewName, params: Record<string, string>): void {
  if (view === "objectDetail" && params.objectName) {
    dispatch({ type: "object-selected", name: params.objectName });
  } else if (view === "procedureDetail" && params.procObject && params.procName) {
    dispatch({ type: "procedure-selected", objectName: params.procObject, procName: params.procName });
  } else if (view === "dwDetail" && params.dwName) {
    dispatch({ type: "dw-selected", name: params.dwName });
  } else {
    dispatch({ type: "navigate", view });
  }
}

export function initViewFromUrl(dispatch: Dispatch<NavigationAction>): void {
  const { view, params } = pathToView(window.location.pathname);
  dispatchFromResolved(dispatch, view, params);
}

// ── Browser back/forward ────────────────────────────────────────────────────

export function setupPopstateHandler(dispatch: Dispatch<NavigationAction>): void {
  window.addEventListener("popstate", () => {
    const { view, params } = pathToView(window.location.pathname);
    dispatchFromResolved(dispatch, view, params);
  });
}
