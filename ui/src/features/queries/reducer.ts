// features/queries/reducer.ts — Queries feature reducer (valtio draft style).

import { Effect } from "../../core/effect.js";
import type { Reducer } from "../../core/reducer.js";
import type { QueriesState } from "./types.js";
import type { QueriesAction } from "./actions.js";
import type { QueryDef, QueryResult } from "../../types/api.js";
import type { NavigationAction } from "../navigation/types.js";

export interface QueriesEnv {
  getQueries(): Effect<{ queries: QueryDef[] }>;
  runQuery(name: string, params: Record<string, string>): Effect<QueryResult>;
  navigate(action: NavigationAction): Effect<never>;
}

export const initialQueriesState: QueriesState = {
  items: [], results: null, resultsName: "", loading: false,
};

function reduce(draft: QueriesState, action: QueriesAction, env: QueriesEnv): Effect<QueriesAction> | null {
  switch (action.type) {
  case "load":
    draft.loading = true;
    return env.getQueries().map((data): QueriesAction => ({ type: "loaded", items: data.queries }));
  case "loaded":
    draft.items = action.items;
    draft.loading = false;
    return null;
  case "run":
    draft.results = null;
    draft.resultsName = action.name;
    return env.runQuery(action.name, action.params)
      .map((data): QueriesAction => ({ type: "result", data }))
      .catch((e): QueriesAction => ({ type: "error", error: String(e) }));
  case "result":
    draft.results = action.data;
    draft.loading = false;
    return null;
  case "error":
    draft.results = { error: action.error };
    draft.loading = false;
    return null;
  default:
    return null;
  }
}

export const queriesReducer: Reducer<QueriesState, QueriesAction, QueriesEnv> = reduce;
