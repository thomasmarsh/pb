// features/navigation/breadcrumb.ts — Derive breadcrumb segments from a Route.

import type { Route, BreadcrumbSegment } from "./types.js";
import { browserTabLabel } from "../explore/browserTabs.js";

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

    case "objectDetail":
      return [
        { icon: ICONS.list,   label: "Browser",   route: { view: "browser" } },
        { icon: ICONS.object, label: route.name,  route },
      ];

    case "procedureDetail":
      return [
        { icon: ICONS.list,      label: "Browser",  route: { view: "browser" } },
        { icon: ICONS.object,    label: route.name, route: { view: "objectDetail", name: route.name } },
        { icon: ICONS.procedure, label: route.proc, route },
      ];

    case "dwDetail":
      return [
        { icon: ICONS.list,       label: browserTabLabel("datawindow"), route: { view: "browser", category: "datawindow" } },
        { icon: ICONS.datawindow, label: route.name,    route },
      ];

    case "tableDetail": {
      const tablesRoute: Route = { view: "browser", category: "tables", ...(route.namespace ? { namespace: route.namespace } : {}) };
      return [
        { icon: ICONS.list,  label: route.namespace ? `Tables — ${route.namespace}` : "Tables", route: tablesRoute },
        { icon: ICONS.table, label: route.name,  route },
      ];
    }

    case "browser":
      return [{ icon: ICONS.list, label: browserTabLabel(route.category), route }];

    case "queries":
      return [{ icon: ICONS.ask, label: "Ask", route }];

    case "diagrams":
      return [{ icon: ICONS.analysis, label: "Schema / ERD", route }];

    case "deadCode":
      return [{ icon: ICONS.analysis, label: "Dead Code", route }];

    case "deadVars":
      return [{ icon: ICONS.analysis, label: "Dead Variables", route }];

    case "typeMismatches":
      return [{ icon: ICONS.analysis, label: "Type Mismatches", route }];

    case "liveProcedures":
      return [{ icon: ICONS.analysis, label: "Live Procedures", route }];

    case "taintExplorer":
      return [{ icon: ICONS.analysis, label: "Taint Explorer", route }];

    case "taintPathView":
      return [
        { icon: ICONS.analysis, label: "Taint Explorer", route: { view: "taintExplorer" } },
        { icon: ICONS.analysis, label: `Path ${route.pathId}`, route },
      ];

    case "sliceView":
      return [
        { icon: ICONS.list,      label: "Browser",         route: { view: "browser" } },
        { icon: ICONS.object,    label: route.object,      route: { view: "objectDetail", name: route.object } },
        { icon: ICONS.procedure, label: route.proc,        route: { view: "procedureDetail", name: route.object, proc: route.proc } },
        { icon: ICONS.analysis,  label: `${route.direction === "backward" ? "Backward" : "Forward"} Slice (line ${route.line})`, route },
      ];

    case "formalReports":
      return [{ icon: ICONS.analysis, label: "Formal Reports", route }];

    case "diagnostics":
      return [{ icon: ICONS.analysis, label: "Diagnostics", route }];

    case "libraryDetail":
      return [{ icon: ICONS.library, label: route.name, route }];

    case "explore":
      return [{ icon: ICONS.analysis, label: "Explore", route }];

    case "cfgDiagram":
      return [
        { icon: ICONS.list,      label: "Browser",          route: { view: "browser" } },
        { icon: ICONS.object,    label: route.object,        route: { view: "objectDetail", name: route.object } },
        { icon: ICONS.procedure, label: route.proc,          route: { view: "procedureDetail", name: route.object, proc: route.proc } },
        { icon: ICONS.analysis,  label: "CFG",              route },
      ];

    case "explainView":
      return [
        { icon: ICONS.list,      label: "Browser",          route: { view: "browser" } },
        { icon: ICONS.object,    label: route.object,        route: { view: "objectDetail", name: route.object } },
        { icon: ICONS.procedure, label: route.proc,          route: { view: "procedureDetail", name: route.object, proc: route.proc } },
        { icon: ICONS.analysis,  label: "Explain",          route },
      ];

    case "launch":
      return [{ icon: ICONS.launch, label: "Launch", route }];
  }
}
