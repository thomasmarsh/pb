// features/explore/reducer.ts — Explore feature reducer (valtio draft style).

import { Effect, type Reducer } from "@pb/core";
import type { ExploreState } from "./types.js";
import type { ExploreAction } from "./actions.js";
import type { ExploreTreeResponse, DwDetailResponse, ExploreProcDetail, TableSummary, TableDetail, ObjectSourceResponse } from "../../types/api.js";
import type { DataWindowFile } from "@pb/interpreter";
import type { NavigationAction } from "../navigation/types.js";

// ── Narrow environment ────────────────────────────────────────────────────────

export interface ExploreEnv {
  getExploreTree(): Effect<ExploreTreeResponse>;
  getExploreProcedure(objectName: string, procName: string): Effect<ExploreProcDetail>;
  getExploreDatawindow(name: string): Effect<DwDetailResponse>;
  getDwLayout(name: string): Effect<DataWindowFile>;
  getObjectSource(name: string): Effect<ObjectSourceResponse>;
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
    selectedObject: null,
    highlightedProcName: null,
    selectedDw: null,
    procCache: {},
    dwCache: {},
    dwLayoutCache: {},
    objectSourceCache: {},
    loading: false,
    activeTab: "source",
    treeFilter: "",
    highlightedLine: null,
    sidebarGroups: { sourceTree: true, entityNav: false, analysisNav: false },
    sidebarCollapsed: false,
    helpOverlayOpen: false,
    tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
  };
}

// ── Auto-reveal helper ────────────────────────────────────────────────────────

function revealInTree(draft: ExploreState, objectName: string): void {
  const lib = draft.libraries.find(l => l.objects.some(o => o.name === objectName));
  if (!lib) return;

  const next = new Set(draft.expandedNodes);
  next.add(`lib:${lib.name}`);
  next.add(`obj:${lib.name}:${objectName}`);

  draft.expandedNodes = next;
  draft.sidebarGroups = { ...draft.sidebarGroups, sourceTree: true };
}

// ── Reducer (mutates draft) ──────────────────────────────────────────────────

function reduce(draft: ExploreState, action: ExploreAction, env: ExploreEnv): Effect<ExploreAction> | null {
  switch (action.tag) {

  case "load":
    draft.loading = true;
    return env.getExploreTree()
      .map((data): ExploreAction => ({ tag: "loaded", data }))
      .catch((): ExploreAction => ({ tag: "loaded", data: { libraries: [] } }));

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

  case "obj-select":
    draft.selectedObject = action.objectName;
    draft.highlightedProcName = null;
    draft.selectedProc = null;
    draft.selectedDw = null;
    draft.highlightedLine = null;
    draft.sidebarGroups = { ...draft.sidebarGroups, sourceTree: true };
    env.navigate({ tag: "navigate", route: { view: "explore" } });
    if (!(action.objectName in draft.objectSourceCache)) {
      return env.getObjectSource(action.objectName)
        .map((data): ExploreAction => ({ tag: "obj-loaded", objectName: action.objectName, data }))
        .catch((e): ExploreAction => ({ tag: "obj-error", objectName: action.objectName, error: String(e) }));
    }
    return null;

  case "obj-loaded":
    draft.objectSourceCache[action.objectName] = action.data;
    return null;

  case "obj-error":
    draft.objectSourceCache[action.objectName] = { error: action.error };
    return null;

  case "proc-select":
    draft.selectedProc = action.nodeId;
    draft.selectedObject = action.objectName;
    draft.highlightedProcName = action.procName;
    draft.selectedDw = null;
    draft.activeTab = "source";
    draft.highlightedLine = null;
    revealInTree(draft, action.objectName);
    env.navigate({ tag: "navigate", route: { view: "explore" } });
    if (!(action.objectName in draft.objectSourceCache)) {
      return env.getObjectSource(action.objectName)
        .map((data): ExploreAction => ({ tag: "obj-loaded", objectName: action.objectName, data }))
        .catch((e): ExploreAction => ({ tag: "obj-error", objectName: action.objectName, error: String(e) }));
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
    draft.selectedObject = null;
    draft.highlightedProcName = null;
    draft.highlightedLine = null;
    revealInTree(draft, action.dwName);
    env.navigate({ tag: "navigate", route: { view: "explore" } });
    if (!(action.nodeId in draft.dwCache)) {
      return Effect.merge(
        env.getExploreDatawindow(action.dwName)
          .map((data): ExploreAction => ({ tag: "dw-loaded", nodeId: action.nodeId, data }))
          .catch((e): ExploreAction => ({ tag: "dw-error", nodeId: action.nodeId, error: String(e) })),
        env.getDwLayout(action.dwName)
          .map((data): ExploreAction => ({ tag: "dw-layout-loaded", nodeId: action.nodeId, data }))
          .catch((): ExploreAction => ({ tag: "dw-layout-error", nodeId: action.nodeId })),
      );
    }
    return null;

  case "dw-loaded":
    draft.dwCache[action.nodeId] = action.data;
    return null;

  case "dw-error":
    draft.dwCache[action.nodeId] = { error: action.error };
    return null;

  case "dw-layout-loaded":
    draft.dwLayoutCache[action.nodeId] = action.data;
    return null;

  case "dw-layout-error":
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

  case "sidebar-toggle-group":
    draft.sidebarGroups = {
      ...draft.sidebarGroups,
      [action.group]: !draft.sidebarGroups[action.group],
    };
    return null;

  case "sidebar-set-collapsed":
    draft.sidebarCollapsed = action.collapsed;
    return null;

  case "sidebar-reveal":
    revealInTree(draft, action.objectName);
    return null;

  case "sidebar-focus-group":
    draft.sidebarGroups = { ...draft.sidebarGroups, [action.group]: true };
    if (draft.sidebarCollapsed) draft.sidebarCollapsed = false;
    return null;

  case "help-overlay-toggle":
    draft.helpOverlayOpen = !draft.helpOverlayOpen;
    return null;

  // Tables browser (state kept; UI now accessed via Entity Navigation → Tables route)
  case "tables-load":
    draft.tables.loading = true;
    return env.getTables()
      .map((items): ExploreAction => ({ tag: "tables-loaded", items }))
      .catch((): ExploreAction => ({ tag: "tables-loaded", items: [] }));

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
      .map((detail): ExploreAction => ({ tag: "tables-detail-loaded", tableName: action.tableName, detail }))
      .catch((e): ExploreAction => ({ tag: "tables-detail-error", tableName: action.tableName, error: String(e) }));

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
