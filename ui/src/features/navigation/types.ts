// features/navigation/types.ts — Navigation types and actions.

export interface NavState {
  view: ViewName;
}

export type ViewName =
  | "dashboard"
  | "objects"
  | "objectDetail"
  | "procedureDetail"
  | "datawindows"
  | "dwDetail"
  | "diagrams"
  | "queries"
  | "search"
  | "explore";

export type NavigationAction =
  | { type: "navigate"; view: ViewName };
