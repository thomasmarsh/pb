// Explore.tsx — Interactive AST tree explorer (layout + wiring).

import { Show, For, onMount, createMemo } from "solid-js";
import { useSnapshot } from "../../core/store.js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import { ExploreStoreContext } from "./ExploreContext.js";
import type { ExploreLibrary, ExploreObject } from "../../types/api.js";
import { LibraryNode } from "./TreeNodes.js";
import { ObjectsDetailPanel, TablesRightPanel } from "./ObjectsDetailPanel.js";
import { TableList } from "./Tables.js";

// ── Main Explore Component ────────────────────────────────────────────────────

export function Explore(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = useSnapshot(store.state);

  onMount(() => {
    store.dispatch({ tag: "nav", action: { type: "navigate", view: "explore" } });
    if (snap().explore.libraries.length === 0 && !snap().explore.loading) {
      store.dispatch({ tag: "explore", action: { type: "load" } });
    }
  });

  const totalObjects = createMemo(() =>
    snap().explore.libraries.reduce((sum: number, lib: ExploreLibrary) => sum + lib.objects.length, 0)
  );

  const totalProcs = createMemo(() =>
    snap().explore.libraries.reduce(
      (sum: number, lib: ExploreLibrary) => sum + lib.objects.reduce((s: number, obj: ExploreObject) => s + obj.procedures.length, 0),
      0
    )
  );

  const leftTab = () => snap().explore.leftTab;

  return (
    <ExploreStoreContext.Provider value={store}>
      <div class="explore-split">
        <div class="explore-left">
          <div class="explore-left-header">
            <h2>AST Explorer</h2>
            <div class="explore-tabs" style={{ "margin-bottom": "6px" }}>
              <button
                class={`explore-tab-btn${leftTab() === "objects" ? " active" : ""}`}
                onClick={() => store.dispatch({ tag: "explore", action: { type: "left-tab", tab: "objects" } })}
              >Objects</button>
              <button
                class={`explore-tab-btn${leftTab() === "tables" ? " active" : ""}`}
                onClick={() => store.dispatch({ tag: "explore", action: { type: "left-tab", tab: "tables" } })}
              >Tables</button>
            </div>
            <Show when={leftTab() === "objects"}>
              <div class="explore-meta">
                <span>{snap().explore.libraries.length} libraries</span>
                <span>{totalObjects()} objects</span>
                <span>{totalProcs()} procedures</span>
              </div>
              <div class="explore-left-actions">
                <button class="filter-pill" onClick={() => store.dispatch({ tag: "explore", action: { type: "expand-all" } })}>
                  Expand All
                </button>
                <button class="filter-pill" onClick={() => store.dispatch({ tag: "explore", action: { type: "collapse-all" } })}>
                  Collapse All
                </button>
              </div>
              <input
                class="explore-filter-input"
                placeholder="Filter…"
                value={snap().explore.treeFilter}
                onInput={(e) => store.dispatch({ tag: "explore", action: { type: "filter", q: e.currentTarget.value } })}
              />
            </Show>
          </div>
          <div class="explore-left-tree">
            <Show when={leftTab() === "objects"} fallback={<TableList store={store} />}>
              <Show
                when={!snap().explore.loading}
                fallback={<div class="loading-overlay"><div class="spinner" /> Loading AST tree...</div>}
              >
                <Show
                  when={snap().explore.libraries.length > 0}
                  fallback={<div class="tree-empty">No data. Run <code>pb ingest</code> first.</div>}
                >
                  <For each={snap().explore.libraries}>
                    {(lib) => <LibraryNode lib={lib} depth={0} />}
                  </For>
                </Show>
              </Show>
            </Show>
          </div>
        </div>
        <div class="explore-right">
          <Show when={leftTab() === "objects"} fallback={<TablesRightPanel store={store} />}>
            <ObjectsDetailPanel />
          </Show>
        </div>
      </div>
    </ExploreStoreContext.Provider>
  );
}
