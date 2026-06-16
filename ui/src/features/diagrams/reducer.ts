// features/diagrams/reducer.ts — Diagrams feature reducer (valtio draft style).

import { Effect } from "../../core/effect.js";
import type { Reducer } from "../../core/reducer.js";
import type { DiagramsState } from "./types.js";
import type { DiagramsAction } from "./actions.js";
import type { NavigationAction } from "../navigation/types.js";

export interface DiagramsEnv {
  getDiagram(kind: string, params: Record<string, string | number>): Effect<string>;
  navigate(action: NavigationAction): Effect<never>;
}

export const initialDiagramsState: DiagramsState = {
  active: "inheritance", svg: null, loading: false, params: {},
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
  default:
    return null;
  }
}

export const diagramsReducer: Reducer<DiagramsState, DiagramsAction, DiagramsEnv> = reduce;
