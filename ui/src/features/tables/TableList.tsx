// features/tables/TableList.tsx — Searchable list of DB tables.

import { For, Show, onMount, onCleanup } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import { EntityCard } from "../../components/EntityCard.js";
import { Loading } from "../../components/Loading.js";

export function TableList(props: { store: Store<AppState, AppAction> }) {
  const snap = props.store.getState();
  const ts = () => snap().tables;
  let cursorIdx = -1;

  // Preserve state: only load if list is empty.
  onMount(() => {
    if (ts().items.length === 0) {
      props.store.dispatch({ tag: "tables", action: { type: "search", q: "" } });
    }
  });

  onMount(() => {
    function handleKey(e: KeyboardEvent): void {
      const t = e.target as HTMLElement;
      if (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable) return;
      const visible = filtered();
      if (e.key === "j") {
        e.preventDefault();
        cursorIdx = Math.min(cursorIdx + 1, visible.length - 1);
        highlightRow(cursorIdx);
      } else if (e.key === "k") {
        e.preventDefault();
        cursorIdx = Math.max(cursorIdx - 1, 0);
        highlightRow(cursorIdx);
      } else if (e.key === "Enter" && cursorIdx >= 0) {
        e.preventDefault();
        const item = visible[cursorIdx];
        if (item) props.store.dispatch({ tag: "tables", action: { type: "select", name: item.table_name } });
      }
    }
    document.addEventListener("keydown", handleKey);
    onCleanup(() => document.removeEventListener("keydown", handleKey));
  });

  function highlightRow(idx: number): void {
    const table = document.querySelector(".table-list-table");
    if (!table) return;
    table.querySelectorAll("tr.list-cursor").forEach((r) => r.classList.remove("list-cursor"));
    const rows = table.querySelectorAll("tbody tr");
    rows[idx]?.classList.add("list-cursor");
    (rows[idx] as HTMLElement)?.scrollIntoView?.({ block: "nearest" });
  }

  // Client-side filter (all tables loaded at once).
  const filtered = () => {
    const q = ts().q.toLowerCase();
    if (!q) return ts().items;
    return ts().items.filter((t) => t.table_name.toLowerCase().includes(q));
  };

  const showingLabel = () => {
    const q = ts().q;
    const f = filtered();
    if (!q) return `Tables (${ts().items.length})`;
    return `Tables — showing ${f.length} of ${ts().items.length}`;
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
            cursorIdx = -1;
            props.store.dispatch({ tag: "tables", action: { type: "filter", q: e.currentTarget.value } });
          }}
        />
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
                      onClick={() => props.store.dispatch({ tag: "tables", action: { type: "select", name: t.table_name } })}
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
