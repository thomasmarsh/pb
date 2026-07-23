// features/errors/reducer.ts — Errors feature reducer (valtio draft style).

import { Effect, type Reducer } from "@pb/core";
import type { ErrorsState } from "./types.js";
import { PAGE_SIZE } from "./types.js";
import type { ErrorsAction } from "./actions.js";
import type { ErrorListResponse, TypeCoverageResponse } from "../../types/api.js";

export interface ErrorsEnv {
  getErrors(params: { kind?: string; q?: string; limit?: number; offset?: number }): Effect<ErrorListResponse>;
  getTypeCoverage(): Effect<TypeCoverageResponse>;
}

export const initialErrorsState: ErrorsState = {
  items: [], total: 0, loading: false, filterKind: "all", query: "", page: 0, selected: null,
  typeCoverage: null,
};

function fetchErrors(draft: ErrorsState, env: ErrorsEnv): Effect<ErrorsAction> {
  return env
    .getErrors({
      kind: draft.filterKind === "all" ? undefined : draft.filterKind,
      q: draft.query || undefined,
      limit: PAGE_SIZE,
      offset: draft.page * PAGE_SIZE,
    })
    .map((data): ErrorsAction => ({ tag: "loaded", items: data.items, total: data.total }))
    .catch((e): ErrorsAction => ({ tag: "error", error: String(e) }));
}

function fetchTypeCoverage(env: ErrorsEnv): Effect<ErrorsAction> {
  return env
    .getTypeCoverage()
    .map((data): ErrorsAction => ({ tag: "typeCoverageLoaded", data }))
    .catch((e): ErrorsAction => ({ tag: "typeCoverageError", error: String(e) }));
}

function reduce(draft: ErrorsState, action: ErrorsAction, env: ErrorsEnv): Effect<ErrorsAction> | null {
  switch (action.tag) {
  case "load":
    draft.loading = true;
    return Effect.merge(fetchErrors(draft, env), fetchTypeCoverage(env));
  case "loaded":
    draft.items = action.items;
    draft.total = action.total;
    draft.loading = false;
    return null;
  case "setFilterKind":
    draft.filterKind = action.kind;
    draft.page = 0;
    draft.loading = true;
    return fetchErrors(draft, env);
  case "setQuery":
    draft.query = action.query;
    draft.page = 0;
    draft.loading = true;
    return fetchErrors(draft, env);
  case "setPage":
    draft.page = action.page;
    draft.loading = true;
    return fetchErrors(draft, env);
  case "select":
    draft.selected = action.row;
    return null;
  case "error":
    draft.loading = false;
    return null;
  case "typeCoverageLoaded":
    draft.typeCoverage = action.data;
    return null;
  case "typeCoverageError":
    return null;
  default:
    return null;
  }
}

export const errorsReducer: Reducer<ErrorsState, ErrorsAction, ErrorsEnv> = reduce;
