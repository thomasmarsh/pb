// features/navigation/types.ts — Navigation types and actions.

export type Route =
  | { view: "dashboard" }
  | { view: "objects" }
  | { view: "objectDetail";    name: string }
  | { view: "procedureDetail"; name: string; proc: string }
  | { view: "datawindows" }
  | { view: "dwDetail";        name: string }
  | { view: "tables" }
  | { view: "tableDetail";     name: string }
  | { view: "diagrams" }
  | { view: "queries" }
  | { view: "search" }
  | { view: "explore" }
  | { view: "errors" };

export type ViewName = Route["view"];

export interface NavState {
  route: Route;
}

export type NavigationAction =
  | { type: "navigate"; route: Route };
