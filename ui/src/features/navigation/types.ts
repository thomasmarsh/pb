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
  | { view: "queries" }
  | { view: "search" }
  | { view: "explore" }
  | { view: "errors" }
  | { view: "libraryDetail"; name: string }
  | { view: "deadCode" }
  | { view: "taintExplorer" }
  | { view: "formalReports" };

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
}

export type NavigationAction =
  | { type: "navigate"; route: Route }
  | { type: "back" }
  | { type: "forward" };
