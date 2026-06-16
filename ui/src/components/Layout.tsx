// Layout.tsx — Sidebar layout. Prop-drilled store.

import { For, type ParentProps } from "solid-js";
import { useSnapshot } from "../core/store.js";
import type { Store } from "../core/store.js";
import type { AppState, ViewName } from "../app/state.js";
import type { Route } from "../features/navigation/types.js";
import type { AppAction } from "../app/actions.js";

const NAV_ITEMS: { path: string; icon: string; label: string }[] = [
  { path: "dashboard", icon: "\u25A6", label: "Dashboard" },
  { path: "objects", icon: "\u25B6", label: "Objects" },
  { path: "datawindows", icon: "\u25A4", label: "DataWindows" },
  { path: "explore", icon: "\u25B8", label: "Explore" },
  { path: "diagrams", icon: "\u25CF", label: "Diagrams" },
  { path: "queries", icon: "\u2318", label: "Queries" },
  { path: "search", icon: "\uD83D\uDD0D", label: "Search" },
];

const VIEW_GROUPS: Record<string, string[]> = {
  objects: ["objects", "objectDetail", "procedureDetail"],
  datawindows: ["datawindows", "dwDetail"],
};

function isActive(itemPath: string, currentView: string): boolean {
  if (itemPath === currentView) return true;
  const group = VIEW_GROUPS[itemPath];
  return group ? group.includes(currentView) : false;
}

interface LayoutProps {
  store: Store<AppState, AppAction>;
}

export function Layout(props: ParentProps<LayoutProps>) {
  const snap = useSnapshot(props.store.state);
  return (
    <div class="app-layout">
      <aside class="sidebar">
        <div class="sidebar-header">
          <h1>pb explore</h1>
          <div class="subtitle">PowerBuilder Codebase Explorer</div>
        </div>
        <nav class="sidebar-nav">
          <For each={NAV_ITEMS}>
            {(item) => (
              <a
                href="#"
                class={isActive(item.path, snap().nav.route.view) ? "active" : ""}
                onClick={(e) => {
                  e.preventDefault();
                  props.store.dispatch({ tag: "nav", action: { type: "navigate", route: { view: item.path as ViewName } as Route } });
                }}
              >
                <span class="icon">{item.icon}</span>
                <span>{item.label}</span>
              </a>
            )}
          </For>
        </nav>
      </aside>
      <main class="main-content">{props.children}</main>
    </div>
  );
}
