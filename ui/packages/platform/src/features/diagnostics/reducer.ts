// features/diagnostics/reducer.ts — Diagnostics feature reducer (valtio draft style).

import { Effect, type Reducer } from "@pb/core";
import type { DiagnosticsState } from "./types.js";
import { PAGE_SIZE } from "./types.js";
import type { DiagnosticsAction } from "./actions.js";
import type { ErrorListResponse, TypeCoverageResponse, DiagnosticsTimelineResponse } from "../../types/api.js";

export interface DiagnosticsEnv {
  getDiagnostics(params: { kind?: string; q?: string; limit?: number; offset?: number }): Effect<ErrorListResponse>;
  getTypeCoverage(): Effect<TypeCoverageResponse>;
  getDiagnosticsTimeline(zoom: number): Effect<DiagnosticsTimelineResponse>;
}

export const initialDiagnosticsState: DiagnosticsState = {
  items: [], total: 0, loading: false, filterKind: "all", query: "", page: 0, selected: null,
  typeCoverage: null,
  timeline: null,
  zoom: 1,
  timelineSvg: "",
};

function fetchDiagnostics(draft: DiagnosticsState, env: DiagnosticsEnv): Effect<DiagnosticsAction> {
  return env
    .getDiagnostics({
      kind: draft.filterKind === "all" ? undefined : draft.filterKind,
      q: draft.query || undefined,
      limit: PAGE_SIZE,
      offset: draft.page * PAGE_SIZE,
    })
    .map((data): DiagnosticsAction => ({ tag: "loaded", items: data.items, total: data.total }))
    .catch((e): DiagnosticsAction => ({ tag: "error", error: String(e) }));
}

function fetchTypeCoverage(env: DiagnosticsEnv): Effect<DiagnosticsAction> {
  return env
    .getTypeCoverage()
    .map((data): DiagnosticsAction => ({ tag: "typeCoverageLoaded", data }))
    .catch((e): DiagnosticsAction => ({ tag: "typeCoverageError", error: String(e) }));
}

function fetchTimeline(env: DiagnosticsEnv, zoom: number): Effect<DiagnosticsAction> {
  return env
    .getDiagnosticsTimeline(zoom)
    .map((data): DiagnosticsAction => ({ tag: "timelineLoaded", data }))
    .catch((e): DiagnosticsAction => ({ tag: "timelineError", error: String(e) }));
}

function reduce(draft: DiagnosticsState, action: DiagnosticsAction, env: DiagnosticsEnv): Effect<DiagnosticsAction> | null {
  switch (action.tag) {
  case "load":
    draft.loading = true;
    return Effect.merge(fetchDiagnostics(draft, env), fetchTypeCoverage(env), fetchTimeline(env, 1));
  case "loaded":
    draft.items = action.items;
    draft.total = action.total;
    draft.loading = false;
    return null;
  case "setFilterKind":
    draft.filterKind = action.kind;
    draft.page = 0;
    draft.loading = true;
    return fetchDiagnostics(draft, env);
  case "setQuery":
    draft.query = action.query;
    draft.page = 0;
    draft.loading = true;
    return fetchDiagnostics(draft, env);
  case "setPage":
    draft.page = action.page;
    draft.loading = true;
    return fetchDiagnostics(draft, env);
  case "select":
    draft.selected = action.row;
    return null;
  case "error":
    draft.loading = false;
    return null;
  case "typeCoverageLoaded":
    draft.typeCoverage = action.data;
    return null;
  case "typeCoverageError":
    return null;
  case "timelineLoaded":
    draft.timeline = action.data;
    draft.timelineSvg = extractSvg(action.data.timeline_html);
    return null;
  case "timelineError":
    return null;
  case "setZoom":
    draft.zoom = action.zoom;
    return fetchTimeline(env, action.zoom);
  default:
    return null;
  }
}

/** Strip <h2>, wrapping <div>, and legend from reporter HTML, keeping only the SVG. */
function extractSvg(html: string): string {
  const m = html.match(/<svg[\s\S]*?<\/svg>/);
  return m ? m[0] : "";
}

export const diagnosticsReducer: Reducer<DiagnosticsState, DiagnosticsAction, DiagnosticsEnv> = reduce;
