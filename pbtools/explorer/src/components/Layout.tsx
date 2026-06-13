// Layout.tsx — Sidebar layout with navigation.

import { A } from "@solidjs/router";
import { For, type ParentProps } from "solid-js";

const NAV_ITEMS = [
  { path: "/", icon: "\u25A6", label: "Dashboard" },
  { path: "/objects", icon: "\u25B6", label: "Objects" },
  { path: "/datawindows", icon: "\u25A4", label: "DataWindows" },
  { path: "/diagrams", icon: "\u25CF", label: "Diagrams" },
  { path: "/queries", icon: "\u2318", label: "Queries" },
  { path: "/search", icon: "\uD83D\uDD0D", label: "Search" },
];

export function Layout(props: ParentProps) {
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
              <A href={item.path} activeClass="active" end={item.path === "/"}>
                <span class="icon">{item.icon}</span>
                <span>{item.label}</span>
              </A>
            )}
          </For>
        </nav>
      </aside>
      <main class="main-content">{props.children}</main>
    </div>
  );
}
