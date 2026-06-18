// features/navigation/breadcrumb.ts — Derive breadcrumb segments from a Route.

import type { Route, BreadcrumbSegment } from "./types.js";

// Segment icons per gap-analysis §1 Q1.
export const ICONS = {
  library:    "◆",
  window:     "⬜",
  object:     "○",
  procedure:  "ƒ",
  datawindow: "▦",
  table:      "⊟",
  ask:        "?",
  analysis:   "◎",
  list:       "≡",
} as const;

export function crumbsForRoute(route: Route): BreadcrumbSegment[] {
  switch (route.view) {
    case "dashboard":
      return [{ icon: ICONS.library, label: "Dashboard", route }];

    case "objects":
      return [{ icon: ICONS.list, label: "Objects", route }];

    case "proceduresList":
      return [{ icon: ICONS.list, label: "Procedures", route }];

    case "objectDetail":
      return [
        { icon: ICONS.list,   label: "Objects",   route: { view: "objects" } },
        { icon: ICONS.object, label: route.name,  route },
      ];

    case "procedureDetail":
      return [
        { icon: ICONS.list,      label: "Objects",  route: { view: "objects" } },
        { icon: ICONS.object,    label: route.name, route: { view: "objectDetail", name: route.name } },
        { icon: ICONS.procedure, label: route.proc, route },
      ];

    case "datawindows":
      return [{ icon: ICONS.list, label: "DataWindows", route }];

    case "dwDetail":
      return [
        { icon: ICONS.list,       label: "DataWindows", route: { view: "datawindows" } },
        { icon: ICONS.datawindow, label: route.name,    route },
      ];

    case "tables":
      return [{ icon: ICONS.list, label: "Tables", route }];

    case "tableDetail":
      return [
        { icon: ICONS.list,  label: "Tables",    route: { view: "tables" } },
        { icon: ICONS.table, label: route.name,  route },
      ];

    case "search":
      return [{ icon: ICONS.list, label: "Search", route }];

    case "queries":
      return [{ icon: ICONS.ask, label: "Ask", route }];

    case "diagrams":
      return [{ icon: ICONS.analysis, label: "Schema / ERD", route }];

    case "deadCode":
      return [{ icon: ICONS.analysis, label: "Dead Code", route }];

    case "taintExplorer":
      return [{ icon: ICONS.analysis, label: "Taint Explorer", route }];

    case "formalReports":
      return [{ icon: ICONS.analysis, label: "Formal Reports", route }];

    case "errors":
      return [{ icon: ICONS.analysis, label: "Diagnostics", route }];

    case "libraryDetail":
      return [{ icon: ICONS.library, label: route.name, route }];

    case "explore":
      return [{ icon: ICONS.analysis, label: "Explore", route }];
  }
}
