// Search.tsx — Global search view.

import { Show, For, createSignal, onMount } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import type { SearchResponse } from "../../types/api.js";
import { TableChip } from "../../components/detail/TableChip.js";
import { procBadge, shortFile } from "../../utils/format.js";
import { debounce } from "../../utils/debounce.js";

function SearchResults(props: { store: Store<AppState, AppAction>; data: SearchResponse }) {
  const store = props.store;
  const data = props.data;
  const tables = () => data.tables ?? [];
  const total = data.objects.length + data.procedures.length + data.datawindows.length + tables().length;

  if (total === 0) {
    return <div class="card"><p style={{ color: "var(--text-muted)" }}>No results found</p></div>;
  }

  return (
    <>
      <Show when={data.objects.length > 0}>
        <div class="card">
          <div class="card-header"><h3>Objects ({data.objects.length})</h3></div>
          <table class="data-table">
            <thead><tr><th>Name</th><th>Kind</th><th>File</th></tr></thead>
            <tbody>
              <For each={data.objects}>
                {(o) => {
                  const bc = o.kind === "powerscript" ? "ps" : "dw";
                  return (
                    <tr class="clickable"
                        onClick={() => store.dispatch({ tag: "objects", action: { tag: "select", name: o.name } })}>
                      <td class="name-cell">{o.name}</td>
                      <td><span class={`badge badge-${bc}`}>{o.kind}</span></td>
                      <td style={{ "font-size": "11px", color: "var(--text-muted)" }}>{shortFile(o.file)}</td>
                    </tr>
                  );
                }}
              </For>
            </tbody>
          </table>
        </div>
      </Show>

      <Show when={data.procedures.length > 0}>
        <div class="card">
          <div class="card-header"><h3>Procedures ({data.procedures.length})</h3></div>
          <table class="data-table">
            <thead><tr><th>Object</th><th>Name</th><th>Type</th><th>Line</th></tr></thead>
            <tbody>
              <For each={data.procedures}>
                {(p) => (
                  <tr class="clickable"
                      onClick={() => store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: p.object, procName: p.name } })}>
                    <td>{p.object}</td>
                    <td class="name-cell">{p.name}</td>
                    <td><span class={`badge ${procBadge(p.proc_type)}`}>{p.proc_type}</span></td>
                    <td style={{ "font-size": "11px", color: "var(--text-muted)" }}>{p.start_line ? String(p.start_line) : ""}</td>
                  </tr>
                )}
              </For>
            </tbody>
          </table>
        </div>
      </Show>

      <Show when={data.datawindows.length > 0}>
        <div class="card">
          <div class="card-header"><h3>DataWindow Controls ({data.datawindows.length})</h3></div>
          <table class="data-table">
            <thead><tr><th>DW</th><th>Control</th><th>Type</th></tr></thead>
            <tbody>
              <For each={data.datawindows}>
                {(d) => (
                  <tr class="clickable"
                      onClick={() => store.dispatch({ tag: "datawindows", action: { tag: "select", name: d.dw_name } })}>
                    <td class="name-cell">{d.dw_name}</td>
                    <td>{d.control_name ?? "–"}</td>
                    <td>{d.control_type ?? ""}</td>
                  </tr>
                )}
              </For>
            </tbody>
          </table>
        </div>
      </Show>

      <Show when={tables().length > 0}>
        <div class="card">
          <div class="card-header"><h3>DB Tables ({tables().length})</h3></div>
          <table class="data-table">
            <thead><tr><th>Table</th><th>DW refs</th><th>PS refs</th></tr></thead>
            <tbody>
              <For each={tables()}>
                {(t) => (
                  <tr>
                    <td><TableChip name={t.table_name} store={store} /></td>
                    <td style={{ color: "var(--text-muted)" }}>{String(t.dw_count)}</td>
                    <td style={{ color: "var(--text-muted)" }}>{String(t.ps_count)}</td>
                  </tr>
                )}
              </For>
            </tbody>
          </table>
        </div>
      </Show>
    </>
  );
}

export function Search(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const se = () => snap().search;
  const [term, setTerm] = createSignal(se().term ?? "");

  onMount(() => {
    store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "search" } } });
  });

  const doSearch = debounce((val: string) => {
    if (val.length >= 2) store.dispatch({ tag: "search", action: { tag: "term", term: val } });
  }, 300);

  return (
    <>
      <div class="search-bar">
        <input
          class="search-input"
          placeholder="Search everything..."
          value={term()}
          onInput={(e) => {
            const val = e.currentTarget.value;
            setTerm(val);
            doSearch(val);
          }}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              const val = term().trim();
              if (val.length >= 1) store.dispatch({ tag: "search", action: { tag: "term", term: val } });
            }
          }}
        />
      </div>

      <Show when={se().loading}>
        <div class="loading-overlay"><div class="spinner" /> Searching...</div>
      </Show>

      <Show when={se().results}>
        <SearchResults store={store} data={se().results!} />
      </Show>
    </>
  );
}
