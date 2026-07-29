// Browser.tsx — Categorized object browser (Plan 210 Phase 2): one tab per
// object category, full-width list per tab. Additive alongside the System Tree.

import { Show, For, onMount } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";
import { EntityCard, Loading, shortFile } from "@pb/platform";

const BROWSER_TABS: { category: string; label: string }[] = [
  { category: "application", label: "Application" },
  { category: "datawindow", label: "DataWindow" },
  { category: "window", label: "Window" },
  { category: "menu", label: "Menu" },
  { category: "userobject", label: "User Object" },
  { category: "function", label: "Function" },
  { category: "system", label: "System" },
];

export function Browser(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const browser = () => snap().explore.browser;

  const label = () => BROWSER_TABS.find((t) => t.category === browser().category)?.label ?? browser().category;

  onMount(() => {
    const r = snap().nav.route;
    const routeCategory = r.view === "browser" ? r.category : undefined;
    if (routeCategory && routeCategory !== browser().category) {
      store.dispatch({ tag: "explore", action: { tag: "browser-tab", category: routeCategory } });
    } else if (browser().items.length === 0 && !browser().loading) {
      store.dispatch({ tag: "explore", action: { tag: "browser-tab", category: browser().category } });
    }
  });

  function selectCategory(category: string): void {
    store.dispatch({ tag: "explore", action: { tag: "browser-tab", category } });
  }

  function selectObject(name: string, category: string): void {
    if (category === "datawindow") {
      store.dispatch({ tag: "explore", action: { tag: "dw-select", dwName: name, nodeId: `dw:${name}` } });
    } else {
      store.dispatch({ tag: "objects", action: { tag: "select", name } });
    }
  }

  return (
    <>
      <div class="filter-pills">
        <For each={BROWSER_TABS}>
          {(tab) => (
            <button
              class={`filter-pill${browser().category === tab.category ? " active" : ""}`}
              onClick={() => selectCategory(tab.category)}
            >
              {tab.label}
            </button>
          )}
        </For>
      </div>

      <Show when={browser().loading && browser().items.length === 0}><Loading /></Show>

      <div class="card">
        <div class="card-header"><h2>{label()} ({browser().items.length})</h2></div>
        <table class="data-table browser-table">
          <thead>
            <tr>
              <th>Name</th>
              <th>File</th>
            </tr>
          </thead>
          <tbody>
            <For each={browser().items} fallback={
              <tr><td colspan="2" style={{ color: "var(--text-muted)", padding: "16px" }}>No {label()} objects.</td></tr>
            }>
              {(obj) => (
                <tr>
                  <td class="name-cell" style={{ padding: "4px 8px" }}>
                    <EntityCard
                      type={obj.category === "datawindow" ? "datawindow" : "object"}
                      name={obj.name}
                      onClick={() => selectObject(obj.name, obj.category)}
                    />
                  </td>
                  <td style={{ "font-size": "11px", color: "var(--text-muted)", "max-width": "400px", overflow: "hidden", "text-overflow": "ellipsis", "white-space": "nowrap" }}>
                    {shortFile(obj.file)}
                  </td>
                </tr>
              )}
            </For>
          </tbody>
        </table>
      </div>
    </>
  );
}
