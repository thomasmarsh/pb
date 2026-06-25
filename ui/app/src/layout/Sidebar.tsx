import { Show, For, type JSX } from "solid-js";
import { Dynamic } from "solid-js/web";
import type { Store } from "@pb/core";
import type { AppState } from "../state.js";
import type { AppAction } from "../actions.js";
import { type Route, type IconComp } from "@pb/platform";
import {
  LayoutDashboard,
  Box,
  Grid3X3,
  Database,
  Code2,
  MessageSquare,
  Search,
  AlertTriangle,
  FolderTree,
  LayoutList,
  BarChart2,
  Sun,
  Moon,
  ChevronLeft,
  ChevronRight,
  ChevronDown,
  Play,
} from "@pb/platform";
import { LibraryNode } from "../../../src/features/explore/TreeNodes.js";

const ENTITY_NAV: { label: string; view: string; icon: IconComp }[] = [
  { label: "Objects",     view: "objects",        icon: Box },
  { label: "DataWindows", view: "datawindows",    icon: Grid3X3 },
  { label: "Tables",      view: "tables",         icon: Database },
  { label: "Procedures",  view: "proceduresList", icon: Code2 },
];

interface AnalysisItem {
  label: string;
  view: string;
  phase: 1 | 2 | 3 | 4;
  gated: boolean;
}

const ANALYSIS_NAV: AnalysisItem[] = [
  { label: "Schema / ERD",   view: "diagrams",      phase: 1, gated: false },
  { label: "Dead Code",      view: "deadCode",      phase: 1, gated: false },
  { label: "Taint Explorer", view: "taintExplorer", phase: 3, gated: true  },
  { label: "Formal Reports", view: "formalReports", phase: 4, gated: true  },
];

const UTIL_NAV: { label: string; view: string; icon: IconComp }[] = [
  { label: "Dashboard",    view: "dashboard", icon: LayoutDashboard },
  { label: "Ask",          view: "queries",   icon: MessageSquare },
  { label: "Search",       view: "search",    icon: Search },
  { label: "Diagnostics",  view: "errors",    icon: AlertTriangle },
];

const RUNTIME_NAV: { label: string; view: string; icon: IconComp }[] = [
  { label: "Launch", view: "launch", icon: Play },
];

const VIEW_GROUPS: Record<string, string[]> = {
  objects:        ["objects", "objectDetail", "procedureDetail"],
  proceduresList: ["proceduresList"],
  datawindows:    ["datawindows", "dwDetail"],
  tables:         ["tables", "tableDetail"],
};

function isActive(itemView: string, currentView: string): boolean {
  if (itemView === currentView) return true;
  const group = VIEW_GROUPS[itemView];
  return group ? group.includes(currentView) : false;
}

function navigateTo(store: Store<AppState, AppAction>, view: string): void {
  if (view === "proceduresList") {
    store.dispatch({ tag: "objects", action: { tag: "procs-list-load" } });
  } else {
    store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view } as Route } });
  }
}

function PhaseBadge(props: { phase: number; gated: boolean }): JSX.Element {
  const cls = () =>
    props.gated ? "phase-badge phase-badge-gated" : "phase-badge phase-badge-active";
  return <span class={cls()}>P{props.phase}</span>;
}

function AnalysisNavItem(props: {
  item: AnalysisItem;
  currentView: string;
  store: Store<AppState, AppAction>;
}): JSX.Element {
  const active = () => isActive(props.item.view, props.currentView);
  const cls = () => {
    let base = "sidebar-entity-link analysis-nav-item";
    if (active()) base += " active";
    if (props.item.gated) base += " gated";
    return base;
  };
  return (
    <a
      href="#"
      class={cls()}
      onClick={(e) => { e.preventDefault(); navigateTo(props.store, props.item.view); }}
      aria-label={`${props.item.label} (P${props.item.phase}${props.item.gated ? ", phase-gated" : ""})`}
    >
      <span class="analysis-nav-label">{props.item.label}</span>
      <PhaseBadge phase={props.item.phase} gated={props.item.gated} />
    </a>
  );
}

function AccordionGroup(props: {
  label: string;
  expanded: boolean;
  onToggle: () => void;
  icon: IconComp;
  children: JSX.Element;
}): JSX.Element {
  return (
    <div class="sidebar-group">
      <button class="sidebar-group-header" onClick={props.onToggle}>
        <span class="sidebar-group-icon"><Dynamic component={props.icon} size={15} /></span>
        <span class="sidebar-group-label">{props.label}</span>
        <span class="sidebar-group-chevron"><ChevronDown size={13} style={{ transform: props.expanded ? "rotate(0deg)" : "rotate(-90deg)", transition: "transform 0.15s" }} /></span>
      </button>
      <Show when={props.expanded}>
        <div class="sidebar-group-body">{props.children}</div>
      </Show>
    </div>
  );
}

interface SidebarProps {
  store: Store<AppState, AppAction>;
  collapsed: boolean;
  sidebarGroups: { sourceTree: boolean; entityNav: boolean; analysisNav: boolean };
  currentView: string;
  onToggleGroup: (group: "sourceTree" | "entityNav" | "analysisNav") => void;
  onSetCollapsed: (collapsed: boolean) => void;
}

export function Sidebar(props: SidebarProps): JSX.Element {
  const store = props.store;
  const snap = store.getState();
  const explore = () => snap().explore;

  return (
    <aside class={`sidebar${props.collapsed ? " sidebar-collapsed" : ""}`}>
      <div class="sidebar-header">
        <div class="sidebar-header-row">
          <h1>pb explore</h1>
          <button
            class="sidebar-collapse-btn"
            onClick={() => props.onSetCollapsed(!props.collapsed)}
            title={props.collapsed ? "Expand sidebar" : "Collapse sidebar"}
          >
            {props.collapsed ? <ChevronRight size={16} /> : <ChevronLeft size={16} />}
          </button>
        </div>
        <Show when={!props.collapsed}>
          <div class="subtitle">PowerBuilder Codebase Explorer</div>
          <button
            class="theme-toggle"
            onClick={() => store.dispatch({ tag: "theme", action: { tag: "toggle" } })}
            title={snap().theme === "dark" ? "Switch to light mode" : "Switch to dark mode"}
          >
            {snap().theme === "dark" ? <Sun size={15} /> : <Moon size={15} />}
          </button>
        </Show>
      </div>

      <Show when={!props.collapsed}>
        <nav class="sidebar-util-nav">
          <For each={UTIL_NAV}>
            {(item) => (
              <a
                href="#"
                class={`sidebar-util-link${isActive(item.view, props.currentView) ? " active" : ""}`}
                onClick={(e) => { e.preventDefault(); navigateTo(store, item.view); }}
              >
                <span class="icon"><Dynamic component={item.icon} size={15} /></span>
                <span>{item.label}</span>
              </a>
            )}
          </For>
        </nav>
      </Show>

      <Show when={props.collapsed}>
        <nav class="sidebar-rail">
          <button
            class="sidebar-rail-icon"
            title="Source Tree"
            onClick={() => { props.onSetCollapsed(false); if (!props.sidebarGroups.sourceTree) props.onToggleGroup("sourceTree"); }}
          ><FolderTree size={16} /></button>
          <button
            class="sidebar-rail-icon"
            title="Entity Navigation"
            onClick={() => { props.onSetCollapsed(false); if (!props.sidebarGroups.entityNav) props.onToggleGroup("entityNav"); }}
          ><LayoutList size={16} /></button>
          <button
            class="sidebar-rail-icon"
            title="Analysis Navigation"
            onClick={() => { props.onSetCollapsed(false); if (!props.sidebarGroups.analysisNav) props.onToggleGroup("analysisNav"); }}
          ><BarChart2 size={16} /></button>
          <For each={UTIL_NAV}>
            {(item) => (
              <button
                class={`sidebar-rail-icon${isActive(item.view, props.currentView) ? " active" : ""}`}
                title={item.label}
                onClick={() => navigateTo(store, item.view)}
              ><Dynamic component={item.icon} size={16} /></button>
            )}
          </For>
          <For each={RUNTIME_NAV}>
            {(item) => (
              <button
                class={`sidebar-rail-icon${isActive(item.view, props.currentView) ? " active" : ""}`}
                title={item.label}
                onClick={() => navigateTo(store, item.view)}
              ><Dynamic component={item.icon} size={16} /></button>
            )}
          </For>
        </nav>
      </Show>

      <Show when={!props.collapsed}>
        <div class="sidebar-groups">
          <AccordionGroup
            label="Source Tree"
            expanded={props.sidebarGroups.sourceTree}
            onToggle={() => props.onToggleGroup("sourceTree")}
            icon={FolderTree}
          >
            <div class="sidebar-tree-controls">
              <button class="filter-pill" onClick={() => store.dispatch({ tag: "explore", action: { tag: "expand-all" } })}>Expand All</button>
              <button class="filter-pill" onClick={() => store.dispatch({ tag: "explore", action: { tag: "collapse-all" } })}>Collapse All</button>
            </div>
            <input
              class="explore-filter-input"
              placeholder="Filter…"
              value={explore().treeFilter}
              onInput={(e) => store.dispatch({ tag: "explore", action: { tag: "filter", q: e.currentTarget.value } })}
            />
            <div class="sidebar-tree-body">
              <Show
                when={!explore().loading}
                fallback={<div class="loading-overlay"><div class="spinner" /> Loading…</div>}
              >
                <Show
                  when={explore().libraries.length > 0}
                  fallback={<div class="tree-empty">No data. Run <code>pb index</code> first.</div>}
                >
                  <For each={explore().libraries}>
                    {(lib) => <LibraryNode lib={lib} depth={0} />}
                  </For>
                </Show>
              </Show>
            </div>
          </AccordionGroup>

          <AccordionGroup
            label="Entity Navigation"
            expanded={props.sidebarGroups.entityNav}
            onToggle={() => props.onToggleGroup("entityNav")}
            icon={LayoutList}
          >
            <nav class="sidebar-entity-nav">
              <For each={ENTITY_NAV}>
                {(item) => (
                  <a
                    href="#"
                    class={`sidebar-entity-link${isActive(item.view, props.currentView) ? " active" : ""}`}
                    onClick={(e) => { e.preventDefault(); navigateTo(store, item.view); }}
                  >
                    <span class="icon"><Dynamic component={item.icon} size={15} /></span>
                    <span>{item.label}</span>
                  </a>
                )}
              </For>
            </nav>
          </AccordionGroup>

          <AccordionGroup
            label="Analysis Navigation"
            expanded={props.sidebarGroups.analysisNav}
            onToggle={() => props.onToggleGroup("analysisNav")}
            icon={BarChart2}
          >
            <nav class="sidebar-entity-nav">
              <For each={ANALYSIS_NAV}>
                {(item) => (
                  <AnalysisNavItem
                    item={item}
                    currentView={props.currentView}
                    store={store}
                  />
                )}
              </For>
            </nav>
          </AccordionGroup>

          <div class="sidebar-section-label">Runtime</div>
          <nav class="sidebar-entity-nav">
            <For each={RUNTIME_NAV}>
              {(item) => (
                <a
                  href="#"
                  class={`sidebar-entity-link${isActive(item.view, props.currentView) ? " active" : ""}`}
                  onClick={(e) => { e.preventDefault(); navigateTo(store, item.view); }}
                >
                  <span class="icon"><Dynamic component={item.icon} size={15} /></span>
                  <span>{item.label}</span>
                </a>
              )}
            </For>
          </nav>
        </div>
      </Show>
    </aside>
  );
}
