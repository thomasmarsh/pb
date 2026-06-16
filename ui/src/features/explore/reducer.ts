// features/explore/reducer.ts — Explore feature reducer (valtio draft style).

import { Effect } from "../../core/effect.js";
import type { Reducer } from "../../core/reducer.js";
import type { ExploreState } from "./types.js";
import type { ExploreAction } from "./actions.js";
import type { ExploreTreeResponse, DwExploreDetail, ExploreProcDetail, TableSummary, TableDetail } from "../../types/api.js";
import type { NavigationAction } from "../navigation/types.js";

// ── Narrow environment ────────────────────────────────────────────────────────

export interface ExploreEnv {
  getExploreTree(): Effect<ExploreTreeResponse>;
  getExploreProcedure(objectName: string, procName: string): Effect<ExploreProcDetail>;
  getExploreDatawindow(name: string): Effect<DwExploreDetail>;
  getTables(): Effect<TableSummary[]>;
  getTableDetail(name: string): Effect<TableDetail>;
  navigate(action: NavigationAction): Effect<never>;
}

// ── Initial state ────────────────────────────────────────────────────────────

function makeInitialExploreState(): ExploreState {
  return {
    libraries: [],
    expandedNodes: new Set<string>(),
    selectedProc: null,
    selectedDw: null,
    procCache: {},
    dwCache: {},
    loading: false,
    activeTab: "source",
    treeFilter: "",
    highlightedLine: null,
    leftTab: "objects",
    tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
  };
}

// ── Reducer (mutates draft) ──────────────────────────────────────────────────

function reduce(draft: ExploreState, action: ExploreAction, env: ExploreEnv): Effect<ExploreAction> | null {
  switch (action.type) {

  case "load":
    draft.loading = true;
    return env.getExploreTree()
      .map((data): ExploreAction => ({ type: "loaded", data }))
      .catch((): ExploreAction => ({ type: "loaded", data: { libraries: [] } }));

  case "loaded":
    draft.libraries = action.data.libraries;
    draft.loading = false;
    return null;

  case "toggle": {
    const cur = draft.expandedNodes;
    if (cur.has(action.nodeId)) {
      const next = new Set(cur);
      next.delete(action.nodeId);
      draft.expandedNodes = next;
    } else {
      draft.expandedNodes = new Set([...cur, action.nodeId]);
    }
    return null;
  }

  case "proc-select":
    draft.selectedProc = action.nodeId;
    draft.selectedDw = null;
    draft.activeTab = "source";
    draft.highlightedLine = null;
    if (!(action.nodeId in draft.procCache)) {
      return env.getExploreProcedure(action.objectName, action.procName)
        .map((data): ExploreAction => ({ type: "proc-loaded", nodeId: action.nodeId, data }))
        .catch((e): ExploreAction => ({ type: "proc-error", nodeId: action.nodeId, error: String(e) }));
    }
    return null;

  case "proc-loaded":
    draft.procCache[action.nodeId] = action.data;
    return null;

  case "proc-error":
    draft.procCache[action.nodeId] = { error: action.error };
    return null;

  case "expand-all": {
    const next = new Set<string>();
    for (const lib of draft.libraries) {
      next.add(`lib:${lib.name}`);
      for (const obj of lib.objects) { next.add(`obj:${lib.name}:${obj.name}`); }
    }
    draft.expandedNodes = next;
    return null;
  }

  case "collapse-all":
    draft.expandedNodes = new Set<string>();
    return null;

  case "dw-select":
    draft.selectedDw = action.nodeId;
    draft.selectedProc = null;
    draft.highlightedLine = null;
    if (!(action.nodeId in draft.dwCache)) {
      return env.getExploreDatawindow(action.dwName)
        .map((data): ExploreAction => ({ type: "dw-loaded", nodeId: action.nodeId, data }))
        .catch((e): ExploreAction => ({ type: "dw-error", nodeId: action.nodeId, error: String(e) }));
    }
    return null;

  case "dw-loaded":
    draft.dwCache[action.nodeId] = action.data;
    return null;

  case "dw-error":
    draft.dwCache[action.nodeId] = { error: action.error };
    return null;

  case "tab":
    draft.activeTab = action.tab;
    return null;

  case "filter":
    draft.treeFilter = action.q;
    return null;

  case "highlight-line":
    draft.highlightedLine = action.line;
    return null;

  // Tables browser
  case "left-tab": {
    draft.leftTab = action.tab;
    if (action.tab === "tables") {
      draft.selectedProc = null;
      draft.selectedDw = null;
      if (draft.tables.items.length === 0 && !draft.tables.loading) {
        draft.tables.loading = true;
        return env.getTables()
          .map((items): ExploreAction => ({ type: "tables-loaded", items }))
          .catch((): ExploreAction => ({ type: "tables-loaded", items: [] }));
      }
    } else {
      draft.tables.selected = null;
      draft.tables.detail = null;
    }
    return null;
  }

  case "tables-load":
    draft.tables.loading = true;
    return env.getTables()
      .map((items): ExploreAction => ({ type: "tables-loaded", items }))
      .catch((): ExploreAction => ({ type: "tables-loaded", items: [] }));

  case "tables-loaded":
    draft.tables.items = action.items;
    draft.tables.loading = false;
    return null;

  case "tables-filter":
    draft.tables.filter = action.q;
    return null;

  case "tables-select":
    draft.selectedDw = null;
    draft.selectedProc = null;
    draft.tables.selected = action.tableName;
    draft.tables.detail = null;
    draft.tables.detailLoading = true;
    return env.getTableDetail(action.tableName)
      .map((detail): ExploreAction => ({ type: "tables-detail-loaded", tableName: action.tableName, detail }))
      .catch((e): ExploreAction => ({ type: "tables-detail-error", tableName: action.tableName, error: String(e) }));

  case "tables-detail-loaded":
    draft.tables.detail = action.detail;
    draft.tables.detailLoading = false;
    return null;

  case "tables-detail-error":
    draft.tables.detail = { error: action.error };
    draft.tables.detailLoading = false;
    return null;

  default:
    return null;
  }
}

export { makeInitialExploreState };
export const exploreReducer: Reducer<ExploreState, ExploreAction, ExploreEnv> = reduce;
