// Search.tsx — Global search view.

import { Show, For, createSignal, onMount } from "solid-js";
import { useStore } from "../context.js";

function shortFile(f: string | null | undefined): string {
  if (!f) return "";
  return f.replace(/\\/g, "/").split("/").slice(-2).join("/");
}

function procBadge(t: string): string {
  return { function: "func", subroutine: "sub", event: "event", on: "on" }[t] ?? "func";
}

function debounce<T extends (...args: never[]) => void>(fn: T, ms: number): T {
  let timer: ReturnType<typeof setTimeout>;
  return ((...args: never[]) => { clearTimeout(timer); timer = setTimeout(() => fn(...args), ms); }) as T;
}

function SearchResults(props: { data: { objects: { name: string; kind: string; file: string }[]; procedures: { object: string; name: string; proc_type: string; start_line: number | null }[]; datawindows: { dw_name: string; control_name: string; control_type: string }[] } }) {
  const store = useStore();
  const data = props.data;
  const total = data.objects.length + data.procedures.length + data.datawindows.length;

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
                        onClick={() => store.dispatch({ type: "OBJECT_SELECTED", name: o.name })}>
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
                      onClick={() => store.dispatch({ type: "PROCEDURE_SELECTED", objectName: p.object, procName: p.name })}>
                    <td>{p.object}</td>
                    <td class="name-cell">{p.name}</td>
                    <td><span class={`badge badge-${procBadge(p.proc_type)}`}>{p.proc_type}</span></td>
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
                      onClick={() => store.dispatch({ type: "DW_SELECTED", name: d.dw_name })}>
                    <td class="name-cell">{d.dw_name}</td>
                    <td>{d.control_name ?? "\u2013"}</td>
                    <td>{d.control_type ?? ""}</td>
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

export function Search() {
  const store = useStore();
  const se = () => store.state.search;
  const [term, setTerm] = createSignal(se().term ?? "");

  onMount(() => {
    store.dispatch({ type: "NAVIGATE", view: "search" });
  });

  const doSearch = debounce((val: string) => {
    if (val.length >= 2) store.dispatch({ type: "SEARCH_TERM", term: val });
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
              if (val.length >= 1) store.dispatch({ type: "SEARCH_TERM", term: val });
            }
          }}
        />
      </div>

      <Show when={se().loading}>
        <div class="loading-overlay"><div class="spinner" /> Searching...</div>
      </Show>

      <Show when={se().results}>
        <SearchResults data={se().results!} />
      </Show>
    </>
  );
}
