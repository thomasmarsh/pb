// features/diagrams/reducer.ts — Diagrams feature reducer (valtio draft style).

import { Effect } from "../../core/effect.js";
import type { Reducer } from "../../core/reducer.js";
import type { DiagramsState } from "./types.js";
import type { DiagramsAction } from "./actions.js";
import type { TableSummary, ListObjectsResponse } from "../../types/api.js";
import type { NavigationAction } from "../navigation/types.js";

export interface DiagramsEnv {
  getDiagram(kind: string, params: Record<string, string | number>): Effect<string>;
  getTables(): Effect<TableSummary[]>;
  getAllObjects(): Effect<ListObjectsResponse>;
  navigate(action: NavigationAction): Effect<never>;
}

export const initialDiagramsState: DiagramsState = {
  active: "inheritance", svg: null, loading: false, params: {},
  tableNames: [], objectNames: [], itemsLoaded: false,
};

function reduce(draft: DiagramsState, action: DiagramsAction, env: DiagramsEnv): Effect<DiagramsAction> | null {
  switch (action.type) {
  case "select":
    draft.active = action.kind;
    draft.svg = null;
    draft.loading = false;
    return null;
  case "params":
    Object.assign(draft.params, action.params);
    return null;
  case "generate":
    draft.loading = true;
    return env.getDiagram(draft.active, draft.params)
      .map((svg): DiagramsAction => ({ type: "loaded", svg }))
      .catch((e): DiagramsAction => ({ type: "error", error: String(e) }));
  case "loaded":
    draft.svg = action.svg;
    draft.loading = false;
    return null;
  case "error":
    draft.svg = null;
    draft.loading = false;
    draft.error = action.error;
    return null;
  case "loadItems":
    if (draft.itemsLoaded) return null;
    return Effect.merge(
      env.getTables()
        .map((tables): DiagramsAction => ({
          type: "itemsLoaded",
          tableNames: tables.map(t => t.table_name),
          objectNames: draft.objectNames,
        })),
      env.getAllObjects()
        .map((data): DiagramsAction => ({
          type: "itemsLoaded",
          tableNames: draft.tableNames,
          objectNames: data.items.map(o => o.name),
        })),
    );
  case "itemsLoaded":
    if (action.tableNames.length > 0) draft.tableNames = action.tableNames;
    if (action.objectNames.length > 0) draft.objectNames = action.objectNames;
    if (draft.tableNames.length > 0 && draft.objectNames.length > 0) draft.itemsLoaded = true;
    return null;
  default:
    return null;
  }
}

export const diagramsReducer: Reducer<DiagramsState, DiagramsAction, DiagramsEnv> = reduce;
