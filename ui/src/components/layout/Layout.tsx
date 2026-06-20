// Layout.tsx — App shell: sidebar + top-bar + keyboard shortcuts.

import { createSignal, onCleanup, type ParentProps } from "solid-js";
import type { JSX } from "solid-js";
import { Search, HelpCircle } from "../../utils/icons.js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import { ExploreStoreContext } from "../../features/explore/ExploreContext.js";
import { BreadcrumbBar } from "./BreadcrumbBar.js";
import { Sidebar } from "./Sidebar.js";
import { useKeyboardShortcuts } from "../../utils/hooks/useKeyboardShortcuts.js";

const MIN_SIDEBAR = 180;
const MAX_SIDEBAR_FRAC = 0.6;

function readSavedWidth(): number {
  try {
    const v = localStorage.getItem("pb-sidebar-width");
    if (v) {
      const n = Number(v);
      if (n >= MIN_SIDEBAR) return n;
    }
  } catch { /* ignore */ }
  return 280;
}

interface LayoutProps {
  store: Store<AppState, AppAction>;
}

export function Layout(props: ParentProps<LayoutProps>): JSX.Element {
  const snap = props.store.getState();
  const currentView = () => snap().nav.route.view;
  const explore = () => snap().explore;
  const sidebarGroups = () => explore().sidebarGroups;
  const sidebarCollapsed = () => explore().sidebarCollapsed;

  const [sidebarWidth, setSidebarWidth] = createSignal(readSavedWidth());
  const [dragging, setDragging] = createSignal(false);

  let startX = 0;
  let startW = 0;

  function onPointerDown(e: PointerEvent): void {
    e.preventDefault();
    startX = e.clientX;
    startW = sidebarWidth();
    setDragging(true);
    document.addEventListener("pointermove", onPointerMove);
    document.addEventListener("pointerup", onPointerUp);
  }

  function onPointerMove(e: PointerEvent): void {
    const maxW = window.innerWidth * MAX_SIDEBAR_FRAC;
    const w = Math.min(maxW, Math.max(MIN_SIDEBAR, startW + (e.clientX - startX)));
    setSidebarWidth(w);
  }

  function onPointerUp(): void {
    setDragging(false);
    document.removeEventListener("pointermove", onPointerMove);
    document.removeEventListener("pointerup", onPointerUp);
    try { localStorage.setItem("pb-sidebar-width", String(sidebarWidth())); } catch { /* ignore */ }
  }

  onCleanup(() => {
    document.removeEventListener("pointermove", onPointerMove);
    document.removeEventListener("pointerup", onPointerUp);
  });

  function toggleGroup(group: "sourceTree" | "entityNav" | "analysisNav"): void {
    props.store.dispatch({ tag: "explore", action: { tag: "sidebar-toggle-group", group } });
  }

  function setCollapsed(collapsed: boolean): void {
    props.store.dispatch({ tag: "explore", action: { tag: "sidebar-set-collapsed", collapsed } });
  }

  useKeyboardShortcuts(props.store);

  const handleLeft = () => `${sidebarCollapsed() ? 44 : sidebarWidth()}px`;

  return (
    <ExploreStoreContext.Provider value={props.store}>
      <div
        class={`app-layout${sidebarCollapsed() ? " sidebar-is-collapsed" : ""}`}
        style={{ "--sidebar-w": `${sidebarCollapsed() ? 44 : sidebarWidth()}px` }}
      >
        <Sidebar
          store={props.store}
          collapsed={sidebarCollapsed()}
          sidebarGroups={sidebarGroups()}
          currentView={currentView()}
          onToggleGroup={toggleGroup}
          onSetCollapsed={setCollapsed}
        />
        <div
          class={`resize-handle${dragging() ? " dragging" : ""}`}
          style={{ left: handleLeft() }}
          onPointerDown={onPointerDown}
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
