// features/tables/TableList.tsx — Searchable list of DB tables.

import { For, Show, onMount } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import { Loading } from "../../components/Loading.js";

export function TableList(props: { store: Store<AppState, AppAction> }) {
  const snap = props.store.getState();
  const ts = () => snap().tables;

  onMount(() => {
    props.store.dispatch({ tag: "tables", action: { type: "search", q: ts().q } });
  });

  return (
    <>
      <div class="search-bar">
        <input
          class="search-input"
          type="text"
          placeholder="Search tables..."
          value={ts().q}
          onInput={(e) =>
            props.store.dispatch({ tag: "tables", action: { type: "search", q: e.currentTarget.value } })
          }
        />
      </div>

      <Show when={ts().loading && ts().items.length === 0}><Loading /></Show>

      <div class="card">
        <div class="card-header"><h2>Tables ({ts().total})</h2></div>
        <table class="data-table">
          <thead>
            <tr>
              <th>Table</th>
              <th>DW refs</th>
              <th>PS SQL refs</th>
              <th>Total files</th>
            </tr>
          </thead>
          <tbody>
            <For each={ts().items} fallback={
              <tr><td colspan="4" style={{ color: "var(--text-muted)", padding: "16px" }}>No tables found.</td></tr>
            }>
              {(t) => (
                <tr
                  class="clickable"
                  onClick={() =>
                    props.store.dispatch({ tag: "tables", action: { type: "select", name: t.table_name } })
                  }
                >
                  <td class="name-cell">{t.table_name}</td>
                  <td>{String(t.dw_count)}</td>
                  <td>{String(t.ps_count)}</td>
                  <td>{String(t.file_count)}</td>
                </tr>
              )}
            </For>
          </tbody>
        </table>
      </div>
    </>
  );
}
