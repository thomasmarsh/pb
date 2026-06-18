import { Show, For, type JSX } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import type { Route } from "../../features/navigation/types.js";
import { chevron } from "../../utils/format.js";
import { LibraryNode } from "../../features/explore/TreeNodes.js";

const ENTITY_NAV: { label: string; view: string; icon: string }[] = [
  { label: "Objects",     view: "objects",        icon: "○" },
  { label: "DataWindows", view: "datawindows",    icon: "▦" },
  { label: "Tables",      view: "tables",         icon: "⊟" },
  { label: "Procedures",  view: "proceduresList", icon: "ƒ" },
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

const UTIL_NAV: { label: string; view: string; icon: string }[] = [
  { label: "Dashboard", view: "dashboard", icon: "◆" },
  { label: "Ask",       view: "queries",   icon: "?" },
  { label: "Search",    view: "search",    icon: "🔍" },
  { label: "Diagnostics", view: "errors",  icon: "⚠" },
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
  icon: string;
  children: JSX.Element;
}): JSX.Element {
  return (
    <div class="sidebar-group">
      <button class="sidebar-group-header" onClick={props.onToggle}>
        <span class="sidebar-group-icon">{props.icon}</span>
        <span class="sidebar-group-label">{props.label}</span>
        <span class="sidebar-group-chevron">{chevron(props.expanded)}</span>
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
            {props.collapsed ? "⟩" : "⟨"}
          </button>
        </div>
        <Show when={!props.collapsed}>
          <div class="subtitle">PowerBuilder Codebase Explorer</div>
          <button
            class="theme-toggle"
            onClick={() => store.dispatch({ tag: "theme", action: { tag: "toggle" } })}
            title={snap().theme === "dark" ? "Switch to light mode" : "Switch to dark mode"}
          >
            {snap().theme === "dark" ? "☀" : "☾"}
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
                <span class="icon">{item.icon}</span>
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
          >🌲</button>
          <button
            class="sidebar-rail-icon"
            title="Entity Navigation"
            onClick={() => { props.onSetCollapsed(false); if (!props.sidebarGroups.entityNav) props.onToggleGroup("entityNav"); }}
          >☰</button>
          <button
            class="sidebar-rail-icon"
            title="Analysis Navigation"
            onClick={() => { props.onSetCollapsed(false); if (!props.sidebarGroups.analysisNav) props.onToggleGroup("analysisNav"); }}
          >◎</button>
          <For each={UTIL_NAV}>
            {(item) => (
              <button
                class={`sidebar-rail-icon${isActive(item.view, props.currentView) ? " active" : ""}`}
                title={item.label}
                onClick={() => navigateTo(store, item.view)}
              >{item.icon}</button>
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
            icon="🌲"
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
            icon="☰"
          >
            <nav class="sidebar-entity-nav">
              <For each={ENTITY_NAV}>
                {(item) => (
                  <a
                    href="#"
                    class={`sidebar-entity-link${isActive(item.view, props.currentView) ? " active" : ""}`}
                    onClick={(e) => { e.preventDefault(); navigateTo(store, item.view); }}
                  >
                    <span class="icon">{item.icon}</span>
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
            icon="◎"
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
        </div>
      </Show>
    </aside>
  );
}
