// features/explore/reducer.ts — Explore feature reducer (valtio draft style).

import { Effect, type Reducer } from "@pb/core";
import type { ExploreState } from "./types.js";
import type { ExploreAction } from "./actions.js";
import type { ExploreTreeResponse, DwDetailResponse, ExploreProcDetail, ObjectSourceResponse, ListObjectsResponse } from "../../types/api.js";
import type { DataWindowFile } from "@pb/interpreter";
import type { NavigationAction } from "../navigation/types.js";

// ── Narrow environment ────────────────────────────────────────────────────────

export interface ExploreEnv {
  getExploreTree(): Effect<ExploreTreeResponse>;
  getExploreProcedure(objectName: string, procName: string): Effect<ExploreProcDetail>;
  getExploreDatawindow(name: string): Effect<DwDetailResponse>;
  getDwLayout(name: string): Effect<DataWindowFile>;
  getObjectSource(name: string): Effect<ObjectSourceResponse>;
  getObjects(params: Record<string, string | number>): Effect<ListObjectsResponse>;
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
    sidebarGroups: { sourceTree: true, analysisNav: false },
    sidebarCollapsed: false,
    helpOverlayOpen: false,
    browser: { category: "all", items: [], loading: false, q: "" },
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

// ── Browser tab fetch ─────────────────────────────────────────────────────────

// Shared by browser-tab (fresh tab, q reset) and browser-filter (typed
// query). "all" carries no category param — the object list is unfiltered
// by category, matching the deleted Objects/Search pages' combined view.
function fetchBrowserCategory(draft: ExploreState, env: ExploreEnv, category: string, q: string): Effect<ExploreAction> {
  draft.browser.loading = true;
  const params: Record<string, string | number> = { limit: 500 };
  if (q) params.q = q;
  if (category !== "all") params.category = category;
  return env.getObjects(params)
    .map((data): ExploreAction => ({ tag: "browser-loaded", data }))
    .catch((): ExploreAction => ({ tag: "browser-loaded", data: { total: 0, offset: 0, limit: 500, items: [] } }));
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

  // Browser panel (Plan 210 Phase 2/211 Phase B)
  case "browser-tab": {
    draft.browser.category = action.category;
    draft.browser.q = "";
    // Tables/Procedures tabs own their state via TableList/ProceduresList's
    // own mount — the object-list fetch below doesn't apply to them.
    if (action.category === "tables" || action.category === "procedures") return null;
    return fetchBrowserCategory(draft, env, action.category, "");
  }

  case "browser-loaded":
    draft.browser.items = action.data.items;
    draft.browser.loading = false;
    return null;

  case "browser-filter":
    draft.browser.q = action.q;
    return fetchBrowserCategory(draft, env, draft.browser.category, action.q);

  default:
    return null;
  }
}

export { makeInitialExploreState };
export const exploreReducer: Reducer<ExploreState, ExploreAction, ExploreEnv> = reduce;
