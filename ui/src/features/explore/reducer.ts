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
    sidebarGroups: { sourceTree: true, entityNav: false, analysisNav: false },
    sidebarCollapsed: false,
    helpOverlayOpen: false,
    tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
  };
}

// ── Auto-reveal helper ────────────────────────────────────────────────────────

function procKindGroup(procType: string): "functions" | "events" | "subroutines" {
  if (procType === "function") return "functions";
  if (procType === "subroutine") return "subroutines";
  return "events"; // "event" | "on"
}

function revealInTree(draft: ExploreState, objectName: string, procName?: string): void {
  const lib = draft.libraries.find(l => l.objects.some(o => o.name === objectName));
  if (!lib) return;

  const next = new Set(draft.expandedNodes);
  next.add(`lib:${lib.name}`);
  next.add(`obj:${lib.name}:${objectName}`);

  if (procName) {
    const obj = lib.objects.find(o => o.name === objectName);
    const proc = obj?.procedures.find(p => p.name === procName);
    if (proc) {
      next.add(`kg:${objectName}:${procKindGroup(proc.proc_type)}`);
    }
  }

  draft.expandedNodes = next;
  draft.sidebarGroups = { ...draft.sidebarGroups, sourceTree: true };
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
    revealInTree(draft, action.objectName, action.procName);
    env.navigate({ type: "navigate", route: { view: "explore" } });
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
    revealInTree(draft, action.dwName);
    env.navigate({ type: "navigate", route: { view: "explore" } });
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
    revealInTree(draft, action.objectName, action.procName);
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
