// features/queries/reducer.ts — Queries feature reducer (valtio draft style).

import { Effect, type Reducer } from "@pb/core";
import { ASK_RUN_KEY, type QueriesState, type QueryRunState } from "./types.js";
import type { QueriesAction } from "./actions.js";
import type { QueryDef, QueryResult } from "../../types/api.js";
import type { NavigationAction, Route } from "../navigation/types.js";

export interface QueriesEnv {
  getQueries(): Effect<{ queries: QueryDef[] }>;
  runQuery(name: string, params: Record<string, string>): Effect<QueryResult>;
  runSql(sql: string): Effect<QueryResult>;
  navigate(action: NavigationAction): Effect<never>;
}

function emptyRun(): QueryRunState {
  return { results: null, queryParams: {}, sql: null, sortCol: null, sortDir: "asc", page: 0, loading: false };
}

export const initialQueriesState: QueriesState = {
  items: [],
  itemsLoading: false,
  runs: {},
  askText: "",
  generatedSql: null,
  queryPaneOpen: false,
  recentQueries: [],
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
  const key = ASK_RUN_KEY;
  draft.generatedSql = sql;
  draft.runs[key] = { ...emptyRun(), sql, loading: true };
  draft.recentQueries = pushRecent(draft.recentQueries, sql);
  env.navigate({ tag: "navigate", route: { view: "queries", sqlText: sql } });
  return env.runSql(sql)
    .map((data): QueriesAction => ({ tag: "result", key, data }))
    .catch((e): QueriesAction => ({ tag: "error", key, error: String(e) }));
}

function reduce(draft: QueriesState, action: QueriesAction, env: QueriesEnv): Effect<QueriesAction> | null {
  switch (action.tag) {
  case "load":
    draft.itemsLoading = true;
    return env.getQueries().map((data): QueriesAction => ({ tag: "loaded", items: data.queries }));
  case "loaded":
    draft.items = action.items;
    draft.itemsLoading = false;
    return null;
  case "run": {
    const key = action.name;
    draft.runs[key] = { ...emptyRun(), queryParams: action.params, loading: true };
    env.navigate({ tag: "navigate", route: { view: "queries", queryName: action.name, queryParams: action.params } });
    return env.runQuery(action.name, action.params)
      .map((data): QueriesAction => ({ tag: "result", key, data }))
      .catch((e): QueriesAction => ({ tag: "error", key, error: String(e) }));
  }
  case "result": {
    const run = draft.runs[action.key] ?? emptyRun();
    run.results = action.data;
    run.loading = false;
    draft.runs[action.key] = run;
    return null;
  }
  case "error": {
    const run = draft.runs[action.key] ?? emptyRun();
    run.results = { error: action.error };
    run.loading = false;
    draft.runs[action.key] = run;
    if (action.key === ASK_RUN_KEY) draft.queryPaneOpen = true;
    return null;
  }
  case "restore": {
    const key = action.name;
    const existing = draft.runs[key];
    if (existing && existing.results !== null) return null;
    draft.runs[key] = { ...(existing ?? emptyRun()), queryParams: action.params };
    return env.runQuery(action.name, action.params)
      .map((data): QueriesAction => ({ tag: "result", key, data }))
      .catch((e): QueriesAction => ({ tag: "error", key, error: String(e) }));
  }
  case "navigate-to-entity": {
    const route = entityRoute(action.entityType, action.entityName, action.objectName);
    if (!route) return null;
    const run = draft.runs[action.key];
    const queryRoute: Route = action.key === ASK_RUN_KEY && run?.sql
      ? { view: "queries", sqlText: run.sql }
      : { view: "queries", queryName: action.key, queryParams: run?.queryParams ?? {} };
    env.navigate({ tag: "navigate-from-ask", route, queryName: action.key, queryRoute });
    return null;
  }
  case "sort": {
    const run = draft.runs[action.key];
    if (!run) return null;
    if (run.sortCol === action.col) {
      run.sortDir = run.sortDir === "asc" ? "desc" : "asc";
    } else {
      run.sortCol = action.col;
      run.sortDir = "asc";
    }
    run.page = 0;
    return null;
  }
  case "set-page": {
    const run = draft.runs[action.key];
    if (!run) return null;
    run.page = action.page;
    return null;
  }
  case "set-ask-text":
    draft.askText = action.text;
    return null;
  case "submit-ask": {
    const text = draft.askText.trim();
    if (!text) return null;
    if (isSqlQuery(text)) {
      return execRunSql(draft, draft.askText.trim(), env);
    }
    draft.runs[ASK_RUN_KEY] = {
      ...emptyRun(),
      results: { error: "NL translation is not available at P1 — start your question with SELECT or WITH to query directly." },
    };
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
