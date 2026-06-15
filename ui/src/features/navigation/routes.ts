// features/navigation/routes.ts — Route registry and URL matching.

import type { ViewName } from "./types.js";

// ── Route definition ────────────────────────────────────────────────────────

export interface RouteSegment {
  toPath: (state: Record<string, unknown>) => string[];
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

// ── Built-in routes ─────────────────────────────────────────────────────────

const _exact: RouteSegment = { toPath: () => [], fromPath: (segs) => segs.length === 0 ? {} : null };
registerRoute("dashboard", _exact);
registerRoute("objects", _exact);
registerRoute("datawindows", _exact);
registerRoute("diagrams", _exact);
registerRoute("queries", _exact);
registerRoute("search", _exact);
registerRoute("explore", _exact);

// ── Entity routes ───────────────────────────────────────────────────────────

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

// ── View prefix mapping ─────────────────────────────────────────────────────

export const VIEW_PREFIX: Record<ViewName, string> = {
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

// ── URL → View ──────────────────────────────────────────────────────────────

export interface ResolvedView {
  view: ViewName;
  params: Record<string, string>;
}

export function pathToView(pathname: string): ResolvedView {
  const segs = pathname.split("/").filter(Boolean);

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

export function viewToPath(view: ViewName, state: Record<string, unknown>): string {
  const prefix = VIEW_PREFIX[view] ?? "/";
  const route = routes.find(r => r.view === view);
  if (!route) return prefix;

  const segments = route.segment.toPath(state);
  return segments.length > 0 ? `${prefix}/${segments.join("/")}` : prefix;
}
