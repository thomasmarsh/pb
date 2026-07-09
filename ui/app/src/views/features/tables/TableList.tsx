// features/tables/TableList.tsx — Searchable list of DB tables.

import { For, Show, onMount } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";
import { EntityCard, Loading, useListKeyboard } from "@pb/platform";

export function TableList(props: { store: Store<AppState, AppAction> }) {
  const snap = props.store.getState();
  const ts = () => snap().tables;
  const routeNamespace = () => {
    const r = snap().nav.route;
    return r.view === "tables" ? r.namespace : undefined;
  };

  onMount(() => {
    props.store.dispatch({ tag: "tables", action: { tag: "mount", namespace: routeNamespace() } });
  });

  useListKeyboard({
    items: () => filtered().map((item) => ({
      select: () => props.store.dispatch({ tag: "tables", action: { tag: "select", name: item.table_name, namespace: item.namespace } }),
    })),
    tableSelector: ".table-list-table",
  });

  // Client-side filter (all tables loaded at once).
  const filtered = () => {
    const q = ts().q.toLowerCase();
    if (!q) return ts().items;
    return ts().items.filter((t) => t.table_name.toLowerCase().includes(q));
  };

  const showingLabel = () => {
    const q = ts().q;
    const f = filtered();
    const label = ts().namespace ? `Tables in ${ts().namespace}` : "Tables";
    if (!q) return `${label} (${ts().items.length})`;
    return `${label} — showing ${f.length} of ${ts().items.length}`;
  };

  return (
    <>
      <div class="search-bar">
        <input
          class="search-input"
          type="text"
          placeholder="Search tables…"
          value={ts().q}
          onInput={(e) => {
            props.store.dispatch({ tag: "tables", action: { tag: "filter", q: e.currentTarget.value } });
          }}
        />
        <Show when={ts().schemas.length > 1}>
          <select
            class="schema-select"
            value={ts().namespace ?? ""}
            onChange={(e) => {
              const namespace = e.currentTarget.value || undefined;
              props.store.dispatch({ tag: "tables", action: { tag: "search", q: ts().q, namespace } });
            }}
          >
            <option value="">All schemas</option>
            <For each={ts().schemas}>
              {(s) => <option value={s.namespace}>{s.namespace}</option>}
            </For>
          </select>
        </Show>
      </div>

      <Show when={ts().loading && ts().items.length === 0}><Loading /></Show>

      <div class="card">
        <div class="card-header"><h2>{showingLabel()}</h2></div>
        <table class="data-table table-list-table">
          <thead>
            <tr>
              <th>Table</th>
              <th>DW refs</th>
              <th>PS SQL refs</th>
              <th>Total files</th>
            </tr>
          </thead>
          <tbody>
            <For each={filtered()} fallback={
              <tr><td colspan="4" style={{ color: "var(--text-muted)", padding: "16px" }}>No tables found.</td></tr>
            }>
              {(t) => (
                <tr>
                  <td class="name-cell" style={{ padding: "4px 8px" }}>
                    <EntityCard
                      type="table"
                      name={t.table_name}
                      onClick={() => props.store.dispatch({ tag: "tables", action: { tag: "select", name: t.table_name, namespace: t.namespace } })}
                    />
                  </td>
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
