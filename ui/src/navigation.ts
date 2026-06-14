// navigation.ts — Route registry. Each component registers its own segments.

import type { ViewName } from "./types/state.js";
import type { Dispatch } from "./core.js";

// ── Route definition ────────────────────────────────────────────────────────

export interface RouteSegment {
  /** Encode state → URL path segments (relative to view root) */
  toPath: (state: Record<string, unknown>) => string[];
  /** Decode URL segments → params (null = no match) */
  fromPath: (segments: string[]) => Record<string, string> | null;
}

interface RegisteredRoute {
  view: ViewName;
  segment: RouteSegment;
}

const routes: RegisteredRoute[] = [];

export function registerRoute(view: ViewName, segment: RouteSegment): void {
  routes.push({ view, segment });
}

// ── Built-in routes (simple views, no segments) ─────────────────────────────

const _exact: RouteSegment = { toPath: () => [], fromPath: (segs) => segs.length === 0 ? {} : null };
registerRoute("dashboard", _exact);
registerRoute("objects", _exact);
registerRoute("datawindows", _exact);
registerRoute("diagrams", _exact);
registerRoute("queries", _exact);
registerRoute("search", _exact);
registerRoute("explore", _exact);

// ── Entity routes (registered by components) ────────────────────────────────

registerRoute("objectDetail", {
  toPath: (s) => {
    const name = (s.objectDetail as { name?: string } | null | undefined)?.name;
    return name ? [encodeURIComponent(name)] : [];
  },
  fromPath: (segs) => segs.length === 1 ? { objectName: decodeURIComponent(segs[0]!) } : null,
});

registerRoute("procedureDetail", {
  toPath: (s) => {
    const pd = s.procedureDetail as { object?: string; name?: string } | null | undefined;
    if (pd?.object && pd?.name) return [encodeURIComponent(pd.object), encodeURIComponent(pd.name)];
    return [];
  },
  fromPath: (segs) => segs.length >= 2
    ? { procObject: decodeURIComponent(segs[0]!), procName: decodeURIComponent(segs[1]!) }
    : null,
});

registerRoute("dwDetail", {
  toPath: (s) => {
    const name = (s.dwDetail as { name?: string } | null | undefined)?.name;
    return name ? [encodeURIComponent(name)] : [];
  },
  fromPath: (segs) => segs.length === 1 ? { dwName: decodeURIComponent(segs[0]!) } : null,
});

// ── URL → View ──────────────────────────────────────────────────────────────

export interface ResolvedView {
  view: ViewName;
  params: Record<string, string>;
}

export function pathToView(pathname: string): ResolvedView {
  const segs = pathname.split("/").filter(Boolean);

  // Strip the view prefix before matching — fromPath receives only entity segments.
  const candidates = routes
    .map(r => {
      const prefixSegs = (VIEW_PREFIX[r.view] ?? "/").split("/").filter(Boolean);
      if (segs.length < prefixSegs.length) return null;
      for (let i = 0; i < prefixSegs.length; i++) {
        if (segs[i] !== prefixSegs[i]) return null;
      }
      const rest = segs.slice(prefixSegs.length);
      const match = r.segment.fromPath(rest);
      return match !== null ? { route: r, match, prefixLen: prefixSegs.length } : null;
    })
    .filter((c): c is { route: RegisteredRoute; match: Record<string, string>; prefixLen: number } => c !== null)
    .sort((a, b) => {
      // Most specific first: prefer longer prefix + more entity segments
      const aSpec = a.prefixLen + a.route.segment.toPath({}).length;
      const bSpec = b.prefixLen + b.route.segment.toPath({}).length;
      return bSpec - aSpec;
    });

  if (candidates.length > 0) {
    return { view: candidates[0]!.route.view, params: candidates[0]!.match };
  }

  return { view: "dashboard", params: {} };
}

// ── State → URL ─────────────────────────────────────────────────────────────

const VIEW_PREFIX: Record<ViewName, string> = {
  dashboard: "/",
  objects: "/objects",
  objectDetail: "/objects",
  procedureDetail: "/objects",
  datawindows: "/datawindows",
  dwDetail: "/datawindows",
  diagrams: "/diagrams",
  queries: "/queries",
  search: "/search",
  explore: "/explore",
};

export function viewToPath(view: ViewName, state: Record<string, unknown>): string {
  const prefix = VIEW_PREFIX[view] ?? "/";
  const route = routes.find(r => r.view === view);
  if (!route) return prefix;

  const segments = route.segment.toPath(state);
  return segments.length > 0 ? `${prefix}/${segments.join("/")}` : prefix;
}

// ── Store → URL sync ────────────────────────────────────────────────────────

export function syncUrlFromState(
  view: ViewName,
  state: Record<string, unknown>,
  action?: { type: string; [key: string]: unknown },
): void {
  let path: string;

  // For actions that clear entity state before loading, build URL from action payload
  if (action?.type === "PROCEDURE_SELECTED" && typeof action.objectName === "string" && typeof action.procName === "string") {
    path = `/objects/${encodeURIComponent(action.objectName)}/${encodeURIComponent(action.procName)}`;
  } else if (action?.type === "OBJECT_SELECTED" && typeof action.name === "string") {
    path = `/objects/${encodeURIComponent(action.name)}`;
  } else if (action?.type === "DW_SELECTED" && typeof action.name === "string") {
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

function dispatchFromResolved(dispatch: Dispatch, view: ViewName, params: Record<string, string>): void {
  if (view === "objectDetail" && params.objectName) {
    dispatch({ type: "OBJECT_SELECTED", name: params.objectName });
  } else if (view === "procedureDetail" && params.procObject && params.procName) {
    dispatch({ type: "PROCEDURE_SELECTED", objectName: params.procObject, procName: params.procName });
  } else if (view === "dwDetail" && params.dwName) {
    dispatch({ type: "DW_SELECTED", name: params.dwName });
  } else {
    dispatch({ type: "NAVIGATE", view });
  }
}

export function initViewFromUrl(dispatch: Dispatch): void {
  const { view, params } = pathToView(window.location.pathname);
  dispatchFromResolved(dispatch, view, params);
}

// ── Browser back/forward ────────────────────────────────────────────────────

export function setupPopstateHandler(dispatch: Dispatch): void {
  window.addEventListener("popstate", () => {
    const { view, params } = pathToView(window.location.pathname);
    dispatchFromResolved(dispatch, view, params);
  });
}
