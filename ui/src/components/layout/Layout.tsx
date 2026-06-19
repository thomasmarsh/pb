// Layout.tsx — App shell: sidebar + top-bar + keyboard shortcuts.

import { type ParentProps } from "solid-js";
import type { JSX } from "solid-js";
import { Search, HelpCircle } from "../../utils/icons.js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import { ExploreStoreContext } from "../../features/explore/ExploreContext.js";
import { BreadcrumbBar } from "./BreadcrumbBar.js";
import { Sidebar } from "./Sidebar.js";
import { useKeyboardShortcuts } from "../../utils/hooks/useKeyboardShortcuts.js";

interface LayoutProps {
  store: Store<AppState, AppAction>;
}

export function Layout(props: ParentProps<LayoutProps>): JSX.Element {
  const snap = props.store.getState();
  const currentView = () => snap().nav.route.view;
  const explore = () => snap().explore;
  const sidebarGroups = () => explore().sidebarGroups;
  const sidebarCollapsed = () => explore().sidebarCollapsed;

  function toggleGroup(group: "sourceTree" | "entityNav" | "analysisNav"): void {
    props.store.dispatch({ tag: "explore", action: { tag: "sidebar-toggle-group", group } });
  }

  function setCollapsed(collapsed: boolean): void {
    props.store.dispatch({ tag: "explore", action: { tag: "sidebar-set-collapsed", collapsed } });
  }

  useKeyboardShortcuts(props.store);

  return (
    <ExploreStoreContext.Provider value={props.store}>
      <div class={`app-layout${sidebarCollapsed() ? " sidebar-is-collapsed" : ""}`}>
        <Sidebar
          store={props.store}
          collapsed={sidebarCollapsed()}
          sidebarGroups={sidebarGroups()}
          currentView={currentView()}
          onToggleGroup={toggleGroup}
          onSetCollapsed={setCollapsed}
        />
        <div class="main-panel">
          <div class="top-bar">
            <BreadcrumbBar store={props.store} />
            <div class="top-bar-actions">
              <button
                class="top-bar-btn"
                title="Search (press /)"
                onClick={() => props.store.dispatch({ tag: "search", action: { tag: "overlay-open" } })}
              ><Search size={15} /></button>
              <button
                class="top-bar-btn"
                title="Keyboard shortcuts (press ?)"
                onClick={() => props.store.dispatch({ tag: "explore", action: { tag: "help-overlay-toggle" } })}
              ><HelpCircle size={15} /></button>
            </div>
          </div>
          <main class="main-content">{props.children}</main>
        </div>
      </div>
    </ExploreStoreContext.Provider>
  );
}
