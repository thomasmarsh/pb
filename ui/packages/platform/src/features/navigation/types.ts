// features/navigation/types.ts — Navigation types and actions.

export type Route =
  | { view: "dashboard" }
  | { view: "objects" }
  | { view: "objectDetail";    name: string }
  | { view: "procedureDetail"; name: string; proc: string }
  | { view: "proceduresList" }
  | { view: "datawindows" }
  | { view: "dwDetail";        name: string }
  | { view: "tables" }
  | { view: "tableDetail";     name: string }
  | { view: "diagrams" }
  | { view: "queries"; queryName?: string; queryParams?: Record<string, string>; sqlText?: string }
  | { view: "search" }
  | { view: "explore" }
  | { view: "errors" }
  | { view: "libraryDetail"; name: string }
  | { view: "deadCode" }
  | { view: "taintExplorer" }
  | { view: "taintPathView"; pathId: number }
  | { view: "sliceView"; object: string; proc: string; line: number; direction: "backward" | "forward" }
  | { view: "formalReports" }
  | { view: "launch" }
  | { view: "cfgDiagram"; object: string; proc: string };

export type ViewName = Route["view"];

export interface BreadcrumbSegment {
  icon: string;
  label: string;
  route: Route;
}

export interface NavState {
  route: Route;
  crumbs: BreadcrumbSegment[];
  history: Route[];
  historyIdx: number;
  askContext: { queryName: string; queryRoute: Route } | null;
}

export type NavigationAction =
  | { tag: "navigate"; route: Route }
  | { tag: "navigate-from-ask"; route: Route; queryName: string; queryRoute: Route }
  | { tag: "back" }
  | { tag: "forward" };
