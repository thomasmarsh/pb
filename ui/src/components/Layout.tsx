// Layout.tsx — Sidebar layout. Pure TCA: dispatch NAVIGATE actions.

import { For, type ParentProps } from "solid-js";
import { useStore } from "../context.js";
import type { ViewName } from "../types/state.js";

const NAV_ITEMS: { path: ViewName; icon: string; label: string }[] = [
  { path: "dashboard", icon: "\u25A6", label: "Dashboard" },
  { path: "objects", icon: "\u25B6", label: "Objects" },
  { path: "datawindows", icon: "\u25A4", label: "DataWindows" },
  { path: "explore", icon: "\u25B8", label: "Explore" },
  { path: "diagrams", icon: "\u25CF", label: "Diagrams" },
  { path: "queries", icon: "\u2318", label: "Queries" },
  { path: "search", icon: "\uD83D\uDD0D", label: "Search" },
];

// Map view names to their sub-detail views for active highlighting
const VIEW_GROUPS: Record<string, ViewName[]> = {
  objects: ["objects", "objectDetail", "procedureDetail"],
  datawindows: ["datawindows", "dwDetail"],
};

function isActive(itemPath: ViewName, currentView: ViewName): boolean {
  if (itemPath === currentView) return true;
  const group = VIEW_GROUPS[itemPath];
  return group ? group.includes(currentView) : false;
}

export function Layout(props: ParentProps) {
  const store = useStore();

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
                class={isActive(item.path, store.state.view) ? "active" : ""}
                onClick={(e) => {
                  e.preventDefault();
                  store.dispatch({ type: "NAVIGATE", view: item.path });
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
