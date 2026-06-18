// features/objects/reducer.ts — Objects feature reducer (valtio draft style).

import { Effect } from "../../core/effect.js";
import type { Reducer } from "../../core/reducer.js";
import type { ObjectsState } from "./types.js";
import type { ObjectsAction } from "./actions.js";
import type {
  ListObjectsResponse, ObjectDetailResponse, ObjectSourceResponse,
  ProcedureDetailResponse,
} from "../../types/api.js";
import type { NavigationAction } from "../navigation/types.js";

export interface ObjectsEnv {
  getObjects(params: Record<string, string | number>): Effect<ListObjectsResponse>;
  getAllObjects(): Effect<ListObjectsResponse>;
  getObject(name: string): Effect<ObjectDetailResponse>;
  getObjectSource(name: string): Effect<ObjectSourceResponse>;
  getProcedure(obj: string, proc: string): Effect<ProcedureDetailResponse>;
  navigate(action: NavigationAction): Effect<never>;
}

export const initialObjectsState: ObjectsState = {
  items: [], total: 0, q: "", kind: "", sort: "name", order: "asc", offset: 0, loading: false,
  detail: null, sourceDetail: null, procedureDetail: null, allObjects: [],
  objectFace: "source", objectScrollPos: {},
  procFace: "source", procScrollPos: {},
};

function errMsg(e: unknown): string { return e instanceof Error ? e.message : String(e); }

function reduce(draft: ObjectsState, action: ObjectsAction, env: ObjectsEnv): Effect<ObjectsAction> | null {
  switch (action.type) {
  case "back-to-objects":
    draft.detail = null;
    draft.sourceDetail = null;
    draft.procedureDetail = null;
    return env.navigate({ type: "navigate", route: { view: "objects" } });
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
  case "select":
    draft.detail = null;
    draft.sourceDetail = null;
    env.navigate({ type: "navigate", route: { view: "objectDetail", name: action.name } });
    return Effect.merge<ObjectsAction>(
      env.getObject(action.name)
        .map((data): ObjectsAction => ({ type: "detail-loaded", data }))
        .catch((e): ObjectsAction => ({ type: "detail-error", error: errMsg(e) })),
      env.getObjectSource(action.name)
        .map((data): ObjectsAction => ({ type: "source-loaded", data }))
        .catch((e): ObjectsAction => ({ type: "source-error", error: errMsg(e) })),
    );
  case "detail-loaded":
    draft.detail = { ...action.data, loading: false };
    return null;
  case "detail-error":
    draft.detail = { error: action.error };
    return null;
  case "source-loaded":
    draft.sourceDetail = { ...action.data, loading: false };
    return null;
  case "source-error":
    draft.sourceDetail = { error: action.error };
    return null;
  case "all-objects-loaded":
    draft.allObjects = action.data;
    return null;
  case "proc-select":
    draft.procedureDetail = null;
    env.navigate({ type: "navigate", route: { view: "procedureDetail", name: action.objectName, proc: action.procName } });
    return env.getProcedure(action.objectName, action.procName)
      .map((data): ObjectsAction => ({ type: "proc-loaded", data }))
      .catch((e): ObjectsAction => ({ type: "proc-error", error: errMsg(e) }));
  case "proc-loaded":
    draft.procedureDetail = { ...action.data, activeTab: "original", loading: false };
    return null;
  case "proc-error":
    draft.procedureDetail = { error: action.error };
    return null;
  case "proc-tab":
    if (draft.procedureDetail && "activeTab" in draft.procedureDetail) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (draft.procedureDetail as any).activeTab = action.tab;
    }
    return null;
  case "set-object-face": {
    const prev = draft.objectScrollPos[action.name] ?? { source: 0, analysis: 0 };
    draft.objectScrollPos[action.name] = {
      ...prev,
      [draft.objectFace]: action.scrollTop,
    };
    draft.objectFace = action.face;
    return null;
  }
  case "set-proc-face": {
    const prev = draft.procScrollPos[action.key] ?? { source: 0, analysis: 0 };
    draft.procScrollPos[action.key] = {
      ...prev,
      [draft.procFace]: action.scrollTop,
    };
    draft.procFace = action.face;
    return null;
  }
  default:
    return null;
  }
}

export const objectsReducer: Reducer<ObjectsState, ObjectsAction, ObjectsEnv> = reduce;
