// Browser.tsx — Consolidated object/table/procedure browser (Plan 210 Phase
// 2 + Plan 211 Phase B): one search bar and one tab strip covering every
// category plus the merged All/Tables/Procedures views.

import { Show, For, createSignal, onMount } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";
import { BROWSER_TABS, browserTabLabel, EntityCard, Loading, shortFile, debounce } from "@pb/platform";
import { BrowserSearchResults } from "./BrowserSearchResults.js";
import { TableList } from "../tables/TableList.js";
import { ProceduresList } from "../objects/ProceduresList.js";

export function Browser(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const browser = () => snap().explore.browser;
  const searchState = () => snap().search;
  const tablesState = () => snap().tables;
  const objectsState = () => snap().objects;

  const label = () => browserTabLabel(browser().category);

  // The search bar's underlying value lives in a different feature's state
  // depending on the active tab — All uses the shared search term, Tables/
  // Procedures use their own list filters, every other category uses
  // browser.q. seedFor resolves which one, used whenever the tab switches.
  function seedFor(category: string): string {
    switch (category) {
      case "all": return searchState().term;
      case "tables": return tablesState().q;
      case "procedures": return objectsState().proceduresListQ;
      default: return browser().q;
    }
  }

  const [text, setText] = createSignal(seedFor(browser().category));

  onMount(() => {
    const r = snap().nav.route;
    const routeCategory = r.view === "browser" ? (r.category ?? "all") : browser().category;
    if (routeCategory !== browser().category) {
      store.dispatch({ tag: "explore", action: { tag: "browser-tab", category: routeCategory } });
      setText(seedFor(routeCategory));
    } else if (
      routeCategory !== "tables" && routeCategory !== "procedures" &&
      browser().items.length === 0 && !browser().loading
    ) {
      store.dispatch({ tag: "explore", action: { tag: "browser-tab", category: routeCategory } });
    }
  });

  function selectCategory(category: string): void {
    store.dispatch({ tag: "explore", action: { tag: "browser-tab", category } });
    setText(seedFor(category));
  }

  function selectObject(name: string, category: string): void {
    if (category === "datawindow") {
      store.dispatch({ tag: "explore", action: { tag: "dw-select", dwName: name, nodeId: `dw:${name}` } });
    } else {
      store.dispatch({ tag: "objects", action: { tag: "select", name } });
    }
  }

  const doAllSearch = debounce((val: string) => {
    if (val.length >= 2) store.dispatch({ tag: "search", action: { tag: "term", term: val } });
  }, 300);

  const doBrowserFilter = debounce((val: string) => {
    store.dispatch({ tag: "explore", action: { tag: "browser-filter", q: val } });
  }, 300);

  function onSearchInput(val: string): void {
    setText(val);
    switch (browser().category) {
      case "all":
        doAllSearch(val);
        break;
      case "tables":
        store.dispatch({ tag: "tables", action: { tag: "filter", q: val } });
        break;
      case "procedures":
        store.dispatch({ tag: "objects", action: { tag: "procs-list-filter", q: val } });
        break;
      default:
        doBrowserFilter(val);
    }
  }

  const placeholder = () => {
    switch (browser().category) {
      case "all": return "Search everything...";
      case "tables": return "Search tables…";
      case "procedures": return "Search procedures or objects…";
      default: return `Search ${label()}…`;
    }
  };

  const showSearchResults = () => browser().category === "all" && text().length >= 2 && searchState().results;

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

      <div class="search-bar">
        <input
          class="search-input"
          placeholder={placeholder()}
          value={text()}
          onInput={(e) => onSearchInput(e.currentTarget.value)}
        />
      </div>

      <Show when={browser().category === "tables"}>
        <TableList store={store} embedded />
      </Show>

      <Show when={browser().category === "procedures"}>
        <ProceduresList store={store} embedded />
      </Show>

      <Show when={browser().category !== "tables" && browser().category !== "procedures"}>
        <Show when={showSearchResults()} fallback={
          <>
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
        }>
          <BrowserSearchResults store={store} data={searchState().results!} />
        </Show>
      </Show>
    </>
  );
}
