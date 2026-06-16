// features/errors/reducer.ts — Errors feature reducer (valtio draft style).

import { Effect } from "../../core/effect.js";
import type { Reducer } from "../../core/reducer.js";
import type { ErrorsState } from "./types.js";
import type { ErrorsAction } from "./actions.js";
import type { ErrorListResponse } from "../../types/api.js";

export interface ErrorsEnv {
  getErrors(params: { kind?: string; q?: string }): Effect<ErrorListResponse>;
}

export const initialErrorsState: ErrorsState = {
  items: [], total: 0, loading: false, filterKind: "all", query: "", selected: null,
};

function fetchErrors(draft: ErrorsState, env: ErrorsEnv): Effect<ErrorsAction> {
  return env
    .getErrors({
      kind: draft.filterKind === "all" ? undefined : draft.filterKind,
      q: draft.query || undefined,
    })
    .map((data): ErrorsAction => ({ type: "loaded", items: data.items, total: data.total }))
    .catch((e): ErrorsAction => ({ type: "error", error: String(e) }));
}

function reduce(draft: ErrorsState, action: ErrorsAction, env: ErrorsEnv): Effect<ErrorsAction> | null {
  switch (action.type) {
  case "load":
    draft.loading = true;
    return fetchErrors(draft, env);
  case "loaded":
    draft.items = action.items;
    draft.total = action.total;
    draft.loading = false;
    return null;
  case "setFilterKind":
    draft.filterKind = action.kind;
    draft.loading = true;
    return fetchErrors(draft, env);
  case "setQuery":
    draft.query = action.query;
    draft.loading = true;
    return fetchErrors(draft, env);
  case "select":
    draft.selected = action.row;
    return null;
  case "error":
    draft.loading = false;
    return null;
  default:
    return null;
  }
}

export const errorsReducer: Reducer<ErrorsState, ErrorsAction, ErrorsEnv> = reduce;
