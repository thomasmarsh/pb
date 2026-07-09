// features/navigation/breadcrumb.ts — Derive breadcrumb segments from a Route.

import type { Route, BreadcrumbSegment } from "./types.js";

// Semantic icon keys — resolved to Lucide components at render time in BreadcrumbBar.
export const ICONS = {
  library:    "library",
  window:     "window",
  object:     "object",
  procedure:  "procedure",
  datawindow: "datawindow",
  table:      "table",
  ask:        "ask",
  analysis:   "analysis",
  list:       "list",
  launch:     "launch",
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

    case "schemas":
      return [{ icon: ICONS.list, label: "Schemas", route }];

    case "tables":
      return route.namespace
        ? [
            { icon: ICONS.list, label: "Schemas",        route: { view: "schemas" } },
            { icon: ICONS.list, label: route.namespace,  route },
          ]
        : [{ icon: ICONS.list, label: "Tables", route }];

    case "tableDetail": {
      const tablesRoute: Route = route.namespace ? { view: "tables", namespace: route.namespace } : { view: "tables" };
      return [
        ...(route.namespace ? [{ icon: ICONS.list, label: "Schemas", route: { view: "schemas" } as Route }] : []),
        { icon: ICONS.list,  label: route.namespace ?? "Tables", route: tablesRoute },
        { icon: ICONS.table, label: route.name,  route },
      ];
    }

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

    case "taintPathView":
      return [
        { icon: ICONS.analysis, label: "Taint Explorer", route: { view: "taintExplorer" } },
        { icon: ICONS.analysis, label: `Path ${route.pathId}`, route },
      ];

    case "sliceView":
      return [
        { icon: ICONS.list,      label: "Objects",         route: { view: "objects" } },
        { icon: ICONS.object,    label: route.object,      route: { view: "objectDetail", name: route.object } },
        { icon: ICONS.procedure, label: route.proc,        route: { view: "procedureDetail", name: route.object, proc: route.proc } },
        { icon: ICONS.analysis,  label: `${route.direction === "backward" ? "Backward" : "Forward"} Slice (line ${route.line})`, route },
      ];

    case "formalReports":
      return [{ icon: ICONS.analysis, label: "Formal Reports", route }];

    case "errors":
      return [{ icon: ICONS.analysis, label: "Diagnostics", route }];

    case "libraryDetail":
      return [{ icon: ICONS.library, label: route.name, route }];

    case "explore":
      return [{ icon: ICONS.analysis, label: "Explore", route }];

    case "cfgDiagram":
      return [
        { icon: ICONS.list,      label: "Objects",          route: { view: "objects" } },
        { icon: ICONS.object,    label: route.object,        route: { view: "objectDetail", name: route.object } },
        { icon: ICONS.procedure, label: route.proc,          route: { view: "procedureDetail", name: route.object, proc: route.proc } },
        { icon: ICONS.analysis,  label: "CFG",              route },
      ];

    case "launch":
      return [{ icon: ICONS.launch, label: "Launch", route }];
  }
}
