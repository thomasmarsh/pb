// Layout.tsx — App shell with 3-group accordion sidebar.

import { Show, For, type ParentProps } from "solid-js";
import type { Store } from "../core/store.js";
import type { AppState, ViewName } from "../app/state.js";
import type { Route } from "../features/navigation/types.js";
import type { AppAction } from "../app/actions.js";
import { ExploreStoreContext } from "../features/explore/ExploreContext.js";
import { LibraryNode } from "../features/explore/TreeNodes.js";
import { chevron } from "../utils/format.js";

// ── Entity nav links (Object/DW/Tables) ──────────────────────────────────────

const ENTITY_NAV: { label: string; view: ViewName; icon: string }[] = [
  { label: "Objects",     view: "objects",     icon: "○" },
  { label: "DataWindows", view: "datawindows", icon: "▦" },
  { label: "Tables",      view: "tables",      icon: "⊟" },
];

// ── Utility nav (non-grouped) ─────────────────────────────────────────────────

const UTIL_NAV: { label: string; view: ViewName; icon: string }[] = [
  { label: "Dashboard", view: "dashboard", icon: "◆" },
  { label: "Queries",   view: "queries",   icon: "⌘" },
  { label: "Search",    view: "search",    icon: "🔍" },
  { label: "Errors",    view: "errors",    icon: "⚠" },
];

// ── View group mapping (for active state) ─────────────────────────────────────

const VIEW_GROUPS: Record<string, string[]> = {
  objects:     ["objects", "objectDetail", "procedureDetail"],
  datawindows: ["datawindows", "dwDetail"],
  tables:      ["tables", "tableDetail"],
};

function isActive(itemView: string, currentView: string): boolean {
  if (itemView === currentView) return true;
  const group = VIEW_GROUPS[itemView];
  return group ? group.includes(currentView) : false;
}

function navigate(store: Store<AppState, AppAction>, view: ViewName) {
  store.dispatch({ tag: "nav", action: { type: "navigate", route: { view } as Route } });
}

// ── Sidebar accordion group ───────────────────────────────────────────────────

function AccordionGroup(props: ParentProps<{ label: string; expanded: boolean; onToggle: () => void; icon: string }>) {
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

// ── Layout ────────────────────────────────────────────────────────────────────

interface LayoutProps {
  store: Store<AppState, AppAction>;
}

export function Layout(props: ParentProps<LayoutProps>) {
  const snap = props.store.getState();
  const isDark = () => snap().theme === "dark";
  const currentView = () => snap().nav.route.view;
  const explore = () => snap().explore;
  const sidebarGroups = () => explore().sidebarGroups;
  const sidebarCollapsed = () => explore().sidebarCollapsed;

  function toggleGroup(group: "sourceTree" | "entityNav" | "analysisNav") {
    props.store.dispatch({ tag: "explore", action: { type: "sidebar-toggle-group", group } });
  }

  function setCollapsed(collapsed: boolean) {
    props.store.dispatch({ tag: "explore", action: { type: "sidebar-set-collapsed", collapsed } });
  }

  return (
    <ExploreStoreContext.Provider value={props.store}>
      <div class={`app-layout${sidebarCollapsed() ? " sidebar-is-collapsed" : ""}`}>
        <aside class={`sidebar${sidebarCollapsed() ? " sidebar-collapsed" : ""}`}>

          {/* Header */}
          <div class="sidebar-header">
            <div class="sidebar-header-row">
              <h1>pb explore</h1>
              <button
                class="sidebar-collapse-btn"
                onClick={() => setCollapsed(!sidebarCollapsed())}
                title={sidebarCollapsed() ? "Expand sidebar" : "Collapse sidebar"}
              >
                {sidebarCollapsed() ? "⟩" : "⟨"}
              </button>
            </div>
            <Show when={!sidebarCollapsed()}>
              <div class="subtitle">PowerBuilder Codebase Explorer</div>
              <button
                class="theme-toggle"
                onClick={() => props.store.dispatch({ tag: "theme", action: { type: "toggle" } })}
                title={isDark() ? "Switch to light mode" : "Switch to dark mode"}
              >
                {isDark() ? "☀" : "☾"}
              </button>
            </Show>
          </div>

          {/* Utility nav */}
          <Show when={!sidebarCollapsed()}>
            <nav class="sidebar-util-nav">
              <For each={UTIL_NAV}>
                {(item) => (
                  <a
                    href="#"
                    class={`sidebar-util-link${isActive(item.view, currentView()) ? " active" : ""}`}
                    onClick={(e) => { e.preventDefault(); navigate(props.store, item.view); }}
                  >
                    <span class="icon">{item.icon}</span>
                    <span>{item.label}</span>
                  </a>
                )}
              </For>
            </nav>
          </Show>

          {/* Icon rail (collapsed) */}
          <Show when={sidebarCollapsed()}>
            <nav class="sidebar-rail">
              <button
                class="sidebar-rail-icon"
                title="Source Tree"
                onClick={() => { setCollapsed(false); if (!sidebarGroups().sourceTree) toggleGroup("sourceTree"); }}
              >🌲</button>
              <button
                class="sidebar-rail-icon"
                title="Entity Navigation"
                onClick={() => { setCollapsed(false); if (!sidebarGroups().entityNav) toggleGroup("entityNav"); }}
              >☰</button>
              <button
                class="sidebar-rail-icon"
                title="Analysis Navigation"
                onClick={() => { setCollapsed(false); if (!sidebarGroups().analysisNav) toggleGroup("analysisNav"); }}
              >◎</button>
              <For each={UTIL_NAV}>
                {(item) => (
                  <button
                    class={`sidebar-rail-icon${isActive(item.view, currentView()) ? " active" : ""}`}
                    title={item.label}
                    onClick={() => navigate(props.store, item.view)}
                  >{item.icon}</button>
                )}
              </For>
            </nav>
          </Show>

          {/* Accordion groups */}
          <Show when={!sidebarCollapsed()}>
            <div class="sidebar-groups">

              {/* Source Tree */}
              <AccordionGroup
                label="Source Tree"
                expanded={sidebarGroups().sourceTree}
                onToggle={() => toggleGroup("sourceTree")}
                icon="🌲"
              >
                <div class="sidebar-tree-controls">
                  <button class="filter-pill" onClick={() => props.store.dispatch({ tag: "explore", action: { type: "expand-all" } })}>Expand All</button>
                  <button class="filter-pill" onClick={() => props.store.dispatch({ tag: "explore", action: { type: "collapse-all" } })}>Collapse All</button>
                </div>
                <input
                  class="explore-filter-input"
                  placeholder="Filter…"
                  value={explore().treeFilter}
                  onInput={(e) => props.store.dispatch({ tag: "explore", action: { type: "filter", q: e.currentTarget.value } })}
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

              {/* Entity Navigation */}
              <AccordionGroup
                label="Entity Navigation"
                expanded={sidebarGroups().entityNav}
                onToggle={() => toggleGroup("entityNav")}
                icon="☰"
              >
                <nav class="sidebar-entity-nav">
                  <For each={ENTITY_NAV}>
                    {(item) => (
                      <a
                        href="#"
                        class={`sidebar-entity-link${isActive(item.view, currentView()) ? " active" : ""}`}
                        onClick={(e) => { e.preventDefault(); navigate(props.store, item.view); }}
                      >
                        <span class="icon">{item.icon}</span>
                        <span>{item.label}</span>
                      </a>
                    )}
                  </For>
                </nav>
              </AccordionGroup>

              {/* Analysis Navigation */}
              <AccordionGroup
                label="Analysis Navigation"
                expanded={sidebarGroups().analysisNav}
                onToggle={() => toggleGroup("analysisNav")}
                icon="◎"
              >
                <nav class="sidebar-entity-nav">
                  <a
                    href="#"
                    class={`sidebar-entity-link${isActive("diagrams", currentView()) ? " active" : ""}`}
                    onClick={(e) => { e.preventDefault(); navigate(props.store, "diagrams"); }}
                  >
                    <span class="icon">◉</span>
                    <span>Diagrams</span>
                  </a>
                </nav>
              </AccordionGroup>

            </div>
          </Show>

        </aside>
        <main class="main-content">{props.children}</main>
      </div>
    </ExploreStoreContext.Provider>
  );
}
