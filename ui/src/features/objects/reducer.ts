// features/objects/reducer.ts — Objects feature reducer (valtio draft style).

import { Effect } from "../../core/effect.js";
import type { Reducer } from "../../core/reducer.js";
import type { ObjectsState } from "./types.js";
import type { ObjectsAction } from "./actions.js";
import type { ListObjectsResponse } from "../../types/api.js";

export interface ObjectsEnv {
  getObjects(params: Record<string, string | number>): Effect<ListObjectsResponse>;
}

export const initialObjectsState: ObjectsState = {
  items: [], total: 0, q: "", kind: "", sort: "name", order: "asc", offset: 0, loading: false,
};

function reduce(draft: ObjectsState, action: ObjectsAction, env: ObjectsEnv): Effect<ObjectsAction> | null {
  switch (action.type) {
  case "search": {
    draft.q = action.q;
    draft.offset = 0;
    draft.loading = true;
    const p = { q: action.q, kind: draft.kind, sort: draft.sort, order: draft.order, limit: 100, offset: 0 };
    return env.getObjects(p).map((data): ObjectsAction => ({ type: "loaded", data }));
  }
  case "filter-kind": {
    draft.kind = action.kind;
    draft.offset = 0;
    draft.loading = true;
    const p = { q: draft.q, kind: action.kind, sort: draft.sort, order: draft.order, limit: 100, offset: 0 };
    return env.getObjects(p).map((data): ObjectsAction => ({ type: "loaded", data }));
  }
  case "sort": {
    draft.order = draft.sort === action.col ? (draft.order === "asc" ? "desc" : "asc") : "asc";
    draft.sort = action.col;
    draft.offset = 0;
    draft.loading = true;
    const p = { q: draft.q, kind: draft.kind, sort: action.col, order: draft.order, limit: 100, offset: 0 };
    return env.getObjects(p).map((data): ObjectsAction => ({ type: "loaded", data }));
  }
  case "page": {
    draft.offset = action.offset;
    draft.loading = true;
    const p = { q: draft.q, kind: draft.kind, sort: draft.sort, order: draft.order, limit: 100, offset: action.offset };
    return env.getObjects(p).map((data): ObjectsAction => ({ type: "loaded", data }));
  }
  case "loaded":
    draft.items = action.data.items;
    draft.total = action.data.total;
    draft.loading = false;
    return null;
  default:
    return null;
  }
}

export const objectsReducer: Reducer<ObjectsState, ObjectsAction, ObjectsEnv> = reduce;
