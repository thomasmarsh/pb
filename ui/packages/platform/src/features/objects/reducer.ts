// features/objects/reducer.ts — Objects feature reducer (valtio draft style).

import { Effect, type Reducer } from "@pb/core";
import type { ObjectsState } from "./types.js";
import type { ObjectsAction } from "./actions.js";
import type {
  ListObjectsResponse, ObjectDetailResponse, ObjectSourceResponse,
  ProcedureDetailResponse, ProcedureListItem, WiringDiagramResponse,
  FootprintResponse, SliceResult,
} from "../../types/api.js";
import { type AstData, type WindowLayout } from "@pb/interpreter";
import type { NavigationAction } from "../navigation/types.js";

export interface ObjectsEnv {
  getObjects(params: Record<string, string | number>): Effect<ListObjectsResponse>;
  getAllObjects(): Effect<ListObjectsResponse>;
  getObject(name: string): Effect<ObjectDetailResponse>;
  getObjectSource(name: string): Effect<ObjectSourceResponse>;
  getObjectAst(name: string): Effect<AstData>;
  getObjectLayout(name: string): Effect<WindowLayout>;
  getProcedure(obj: string, proc: string): Effect<ProcedureDetailResponse>;
  getProcedures(): Effect<ProcedureListItem[]>;
  getWiringDiagram(obj: string, proc: string): Effect<WiringDiagramResponse>;
  getFootprint(object: string, proc?: string): Effect<FootprintResponse>;
  getSlice(object: string, proc: string, line: number, direction: "backward" | "forward"): Effect<SliceResult>;
  navigate(action: NavigationAction): Effect<never>;
}

export const initialObjectsState: ObjectsState = {
  items: [], total: 0, q: "", kind: "", sort: "name", order: "asc", offset: 0, loading: false,
  detail: null, sourceDetail: null, astData: null, layout: null, selectedProcName: null, procedureDetail: null, allObjects: [],
  proceduresList: null, proceduresListLoading: false,
  proceduresListQ: "", proceduresListKind: "",
  proceduresListSort: "name", proceduresListOrder: "asc",
  wiringDiagram: null, wiringDiagramLoading: false,
  footprint: null, footprintLoading: false,
  sliceHighlight: null, sliceHighlightLoading: false,
  scrollToLine: null,
};

function errMsg(e: unknown): string { return e instanceof Error ? e.message : String(e); }

function reduce(draft: ObjectsState, action: ObjectsAction, env: ObjectsEnv): Effect<ObjectsAction> | null {
  switch (action.tag) {
  case "back-to-objects":
    draft.detail = null;
    draft.sourceDetail = null;
    draft.astData = null;
    draft.layout = null;
    draft.procedureDetail = null;
    return env.navigate({ tag: "navigate", route: { view: "browser" } });
  case "search": {
    draft.q = action.q;
    draft.offset = 0;
    draft.loading = true;
    const p = { q: action.q, kind: draft.kind, sort: draft.sort, order: draft.order, limit: 100, offset: 0 };
    return env.getObjects(p).map((data): ObjectsAction => ({ tag: "loaded", data }));
  }
  case "filter-kind": {
    draft.kind = action.kind;
    draft.offset = 0;
    draft.loading = true;
    const p = { q: draft.q, kind: action.kind, sort: draft.sort, order: draft.order, limit: 100, offset: 0 };
    return env.getObjects(p).map((data): ObjectsAction => ({ tag: "loaded", data }));
  }
  case "sort": {
    draft.order = draft.sort === action.col ? (draft.order === "asc" ? "desc" : "asc") : "asc";
    draft.sort = action.col;
    draft.offset = 0;
    draft.loading = true;
    const p = { q: draft.q, kind: draft.kind, sort: action.col, order: draft.order, limit: 100, offset: 0 };
    return env.getObjects(p).map((data): ObjectsAction => ({ tag: "loaded", data }));
  }
  case "page": {
    draft.offset = action.offset;
    draft.loading = true;
    const p = { q: draft.q, kind: draft.kind, sort: draft.sort, order: draft.order, limit: 100, offset: action.offset };
    return env.getObjects(p).map((data): ObjectsAction => ({ tag: "loaded", data }));
  }
  case "loaded":
    draft.items = action.data.items;
    draft.total = action.data.total;
    draft.loading = false;
    return null;
  case "select":
    draft.detail = null;
    draft.sourceDetail = null;
    draft.astData = null;
    draft.layout = null;
    draft.selectedProcName = null;
    draft.scrollToLine = action.scrollToLine ?? null;
    env.navigate({ tag: "navigate", route: { view: "objectDetail", name: action.name } });
    return Effect.merge<ObjectsAction>(
      env.getObject(action.name)
        .map((data): ObjectsAction => ({ tag: "detail-loaded", data }))
        .catch((e): ObjectsAction => ({ tag: "detail-error", error: errMsg(e) })),
      env.getObjectSource(action.name)
        .map((data): ObjectsAction => ({ tag: "source-loaded", data }))
        .catch((e): ObjectsAction => ({ tag: "source-error", error: errMsg(e) })),
      env.getObjectAst(action.name)
        .map((data): ObjectsAction => ({ tag: "ast-loaded", data }))
        .catch((e): ObjectsAction => ({ tag: "ast-error", error: errMsg(e) })),
      env.getObjectLayout(action.name)
        .map((data): ObjectsAction => ({ tag: "layout-loaded", data }))
        .catch((): ObjectsAction => ({ tag: "layout-error", error: "" })),
    );
  case "select-proc": {
    draft.selectedProcName = action.procName;
    const alreadyLoaded = draft.detail && "name" in draft.detail && draft.detail.name === action.objectName;
    if (!alreadyLoaded) {
      draft.detail = null;
      draft.sourceDetail = null;
      draft.astData = null;
      draft.layout = null;
      env.navigate({ tag: "navigate", route: { view: "objectDetail", name: action.objectName } });
      return Effect.merge<ObjectsAction>(
        env.getObject(action.objectName)
          .map((data): ObjectsAction => ({ tag: "detail-loaded", data }))
          .catch((e): ObjectsAction => ({ tag: "detail-error", error: errMsg(e) })),
        env.getObjectSource(action.objectName)
          .map((data): ObjectsAction => ({ tag: "source-loaded", data }))
          .catch((e): ObjectsAction => ({ tag: "source-error", error: errMsg(e) })),
        env.getObjectAst(action.objectName)
          .map((data): ObjectsAction => ({ tag: "ast-loaded", data }))
          .catch((e): ObjectsAction => ({ tag: "ast-error", error: errMsg(e) })),
        env.getObjectLayout(action.objectName)
          .map((data): ObjectsAction => ({ tag: "layout-loaded", data }))
          .catch((): ObjectsAction => ({ tag: "layout-error", error: "" })),
      );
    }
    env.navigate({ tag: "navigate", route: { view: "objectDetail", name: action.objectName } });
    return null;
  }
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
  case "ast-loaded":
    draft.astData = action.data;
    return null;
  case "ast-error":
    draft.astData = { error: action.error };
    return null;
  case "layout-loaded":
    draft.layout = action.data;
    return null;
  case "layout-error":
    return null;
  case "all-objects-loaded":
    draft.allObjects = action.data;
    return null;
  case "proc-select":
    draft.procedureDetail = null;
    draft.wiringDiagram = null;
    draft.wiringDiagramLoading = false;
    draft.footprint = null;
    draft.footprintLoading = false;
    draft.sliceHighlight = null;
    draft.sliceHighlightLoading = false;
    env.navigate({ tag: "navigate", route: { view: "procedureDetail", name: action.objectName, proc: action.procName } });
    return env.getProcedure(action.objectName, action.procName)
      .map((data): ObjectsAction => ({ tag: "proc-loaded", data }))
      .catch((e): ObjectsAction => ({ tag: "proc-error", error: errMsg(e) }));
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
  case "procs-list-load":
    if (draft.proceduresList !== null) {
      env.navigate({ tag: "navigate", route: { view: "browser", category: "procedures" } });
      return null;
    }
    draft.proceduresListLoading = true;
    env.navigate({ tag: "navigate", route: { view: "browser", category: "procedures" } });
    return env.getProcedures()
      .map((data): ObjectsAction => ({ tag: "procs-list-loaded", data }))
      .catch((e): ObjectsAction => ({ tag: "procs-list-error", error: errMsg(e) }));
  case "procs-list-loaded":
    draft.proceduresList = action.data;
    draft.proceduresListLoading = false;
    return null;
  case "procs-list-error":
    draft.proceduresListLoading = false;
    return null;
  case "procs-list-filter":
    draft.proceduresListQ = action.q;
    return null;
  case "procs-list-filter-kind":
    draft.proceduresListKind = action.kind;
    return null;
  case "procs-list-sort":
    if (draft.proceduresListSort === action.col) {
      draft.proceduresListOrder = draft.proceduresListOrder === "asc" ? "desc" : "asc";
    } else {
      draft.proceduresListSort = action.col;
      draft.proceduresListOrder = "asc";
    }
    return null;
  case "go-slice":
    env.navigate({ tag: "navigate", route: { view: "sliceView", object: action.object, proc: action.proc, line: action.line, direction: action.direction } });
    return null;
  case "highlight-slice":
    draft.sliceHighlightLoading = true;
    draft.sliceHighlight = null;
    return env.getSlice(action.object, action.proc, action.line, action.direction)
      .map((data): ObjectsAction => ({ tag: "highlight-slice-loaded", object: action.object, proc: action.proc, data }))
      .catch((e): ObjectsAction => ({ tag: "highlight-slice-error", error: errMsg(e) }));
  case "highlight-slice-loaded":
    draft.sliceHighlight = { ...action.data, object: action.object, proc: action.proc };
    draft.sliceHighlightLoading = false;
    return null;
  case "highlight-slice-error":
    draft.sliceHighlight = { error: action.error };
    draft.sliceHighlightLoading = false;
    return null;
  case "clear-slice-highlight":
    draft.sliceHighlight = null;
    draft.sliceHighlightLoading = false;
    return null;
  case "wiring-load": {
    const already = draft.wiringDiagram
      && "nodes" in draft.wiringDiagram
      && draft.wiringDiagram.object === action.objectName
      && draft.wiringDiagram.proc === action.procName;
    if (already || draft.wiringDiagramLoading) return null;
    draft.wiringDiagramLoading = true;
    return env.getWiringDiagram(action.objectName, action.procName)
      .map((data): ObjectsAction => ({ tag: "wiring-loaded", objectName: action.objectName, procName: action.procName, data }))
      .catch((e): ObjectsAction => ({ tag: "wiring-error", error: errMsg(e) }));
  }
  case "wiring-loaded":
    draft.wiringDiagram = { ...action.data, object: action.objectName, proc: action.procName };
    draft.wiringDiagramLoading = false;
    return null;
  case "wiring-error":
    draft.wiringDiagram = { error: action.error };
    draft.wiringDiagramLoading = false;
    return null;
  case "footprint-load": {
    const already = draft.footprint
      && "object" in draft.footprint
      && draft.footprint.object === action.objectName
      && draft.footprint.proc_name === action.procName;
    if (already || draft.footprintLoading) return null;
    draft.footprintLoading = true;
    return env.getFootprint(action.objectName, action.procName)
      .map((data): ObjectsAction => ({ tag: "footprint-loaded", data }))
      .catch((e): ObjectsAction => ({ tag: "footprint-error", error: errMsg(e) }));
  }
  case "footprint-loaded":
    draft.footprint = action.data;
    draft.footprintLoading = false;
    return null;
  case "footprint-error":
    draft.footprint = { error: action.error };
    draft.footprintLoading = false;
    return null;
  default:
    return null;
  }
}

export const objectsReducer: Reducer<ObjectsState, ObjectsAction, ObjectsEnv> = reduce;
