// features/queries/reducer.ts — Queries feature reducer (valtio draft style).

import { Effect, type Reducer } from "@pb/core";
import type { QueriesState } from "./types.js";
import type { QueriesAction } from "./actions.js";
import type { QueryDef, QueryResult } from "../../types/api.js";
import type { NavigationAction, Route } from "../navigation/types.js";

export interface QueriesEnv {
  getQueries(): Effect<{ queries: QueryDef[] }>;
  runQuery(name: string, params: Record<string, string>): Effect<QueryResult>;
  runSql(sql: string): Effect<QueryResult>;
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
  askText: "",
  generatedSql: null,
  queryPaneOpen: false,
  recentQueries: [],
  isSqlMode: false,
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

function isSqlQuery(text: string): boolean {
  const t = text.trimStart().toUpperCase();
  return t.startsWith("SELECT") || t.startsWith("WITH");
}

function pushRecent(current: string[], sql: string): string[] {
  const deduped = current.filter((q) => q !== sql);
  return [sql, ...deduped].slice(0, 5);
}

function execRunSql(draft: QueriesState, sql: string, env: QueriesEnv): Effect<QueriesAction> {
  draft.generatedSql = sql;
  draft.resultsName = sql.slice(0, 50);
  draft.isSqlMode = true;
  draft.results = null;
  draft.page = 0;
  draft.loading = true;
  draft.recentQueries = pushRecent(draft.recentQueries, sql);
  env.navigate({ tag: "navigate", route: { view: "queries", sqlText: sql } });
  return env.runSql(sql)
    .map((data): QueriesAction => ({ tag: "result", data }))
    .catch((e): QueriesAction => ({ tag: "error", error: String(e) }));
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
    draft.isSqlMode = false;
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
    draft.queryPaneOpen = true;
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
    const queryRoute: Route = draft.isSqlMode && draft.generatedSql
      ? { view: "queries", sqlText: draft.generatedSql }
      : { view: "queries", queryName: draft.resultsName, queryParams: draft.queryParams };
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
  case "set-ask-text":
    draft.askText = action.text;
    return null;
  case "submit-ask": {
    const text = draft.askText.trim();
    if (!text) return null;
    if (isSqlQuery(text)) {
      return execRunSql(draft, draft.askText.trim(), env);
    }
    draft.results = { error: "NL translation is not available at P1 — start your question with SELECT or WITH to query directly." };
    return null;
  }
  case "toggle-query-pane":
    draft.queryPaneOpen = !draft.queryPaneOpen;
    return null;
  case "set-generated-sql":
    draft.generatedSql = action.sql;
    return null;
  case "run-sql":
    return execRunSql(draft, action.sql, env);
  case "run-recent":
    draft.askText = action.text;
    return execRunSql(draft, action.text, env);
  default:
    return null;
  }
}

export const queriesReducer: Reducer<QueriesState, QueriesAction, QueriesEnv> = reduce;
