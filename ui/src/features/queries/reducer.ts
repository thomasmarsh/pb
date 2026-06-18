// features/queries/reducer.ts — Queries feature reducer (valtio draft style).

import { Effect } from "../../core/effect.js";
import type { Reducer } from "../../core/reducer.js";
import type { QueriesState } from "./types.js";
import type { QueriesAction } from "./actions.js";
import type { QueryDef, QueryResult } from "../../types/api.js";
import type { NavigationAction, Route } from "../navigation/types.js";

export interface QueriesEnv {
  getQueries(): Effect<{ queries: QueryDef[] }>;
  runQuery(name: string, params: Record<string, string>): Effect<QueryResult>;
  navigate(action: NavigationAction): Effect<never>;
}

export const initialQueriesState: QueriesState = {
  items: [],
  results: null,
  resultsName: "",
  queryParams: {},
  sortCol: null,
  sortDir: "asc",
  page: 0,
  loading: false,
};

function entityRoute(entityType: string, entityName: string, objectName: string | null): Route | null {
  switch (entityType) {
    case "object":     return { view: "objectDetail", name: entityName };
    case "procedure":  return objectName ? { view: "procedureDetail", name: objectName, proc: entityName } : null;
    case "datawindow": return { view: "dwDetail", name: entityName };
    case "table":      return { view: "tableDetail", name: entityName };
    default:           return null;
  }
}

function reduce(draft: QueriesState, action: QueriesAction, env: QueriesEnv): Effect<QueriesAction> | null {
  switch (action.tag) {
  case "load":
    draft.loading = true;
    return env.getQueries().map((data): QueriesAction => ({ tag: "loaded", items: data.queries }));
  case "loaded":
    draft.items = action.items;
    draft.loading = false;
    return null;
  case "run":
    draft.results = null;
    draft.resultsName = action.name;
    draft.queryParams = action.params;
    draft.page = 0;
    env.navigate({ tag: "navigate", route: { view: "queries", queryName: action.name, queryParams: action.params } });
    return env.runQuery(action.name, action.params)
      .map((data): QueriesAction => ({ tag: "result", data }))
      .catch((e): QueriesAction => ({ tag: "error", error: String(e) }));
  case "result":
    draft.results = action.data;
    draft.loading = false;
    return null;
  case "error":
    draft.results = { error: action.error };
    draft.loading = false;
    return null;
  case "restore":
    if (draft.resultsName === action.name && draft.results !== null) return null;
    draft.resultsName = action.name;
    draft.queryParams = action.params;
    return env.runQuery(action.name, action.params)
      .map((data): QueriesAction => ({ tag: "result", data }))
      .catch((e): QueriesAction => ({ tag: "error", error: String(e) }));
  case "navigate-to-entity": {
    const route = entityRoute(action.entityType, action.entityName, action.objectName);
    if (!route) return null;
    const queryRoute: Route = { view: "queries", queryName: draft.resultsName, queryParams: draft.queryParams };
    env.navigate({ tag: "navigate-from-ask", route, queryName: draft.resultsName, queryRoute });
    return null;
  }
  case "sort":
    if (draft.sortCol === action.col) {
      draft.sortDir = draft.sortDir === "asc" ? "desc" : "asc";
    } else {
      draft.sortCol = action.col;
      draft.sortDir = "asc";
    }
    draft.page = 0;
    return null;
  case "set-page":
    draft.page = action.page;
    return null;
  default:
    return null;
  }
}

export const queriesReducer: Reducer<QueriesState, QueriesAction, QueriesEnv> = reduce;
