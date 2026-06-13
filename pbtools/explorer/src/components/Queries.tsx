// Queries.tsx — SQL queries view.

import { Show, For } from "solid-js";
import { useStore } from "../context.js";

export function Queries() {
  const store = useStore();
  const q = () => store.state.queries;
  const inputs = new Map<string, HTMLInputElement>();

  function handleRun(queryName: string, params: { name: string; type: string; default: string | null }[]) {
    const bound: Record<string, string> = {};
    for (const p of params) {
      const inp = inputs.get(p.name);
      if (inp?.value) bound[p.name] = inp.value;
      else if (p.default) bound[p.name] = p.default;
    }
    store.dispatch({ type: "QUERY_RUN", name: queryName, params: bound });
  }

  return (
    <div class="card">
      <div class="card-header"><h2>SQL Queries</h2></div>

      <For each={q().items}>
        {(query) => (
          <div style={{ "margin-bottom": "16px", "padding-bottom": "16px", "border-bottom": "1px solid var(--border)" }}>
            <div style={{ "font-weight": "600", "margin-bottom": "4px" }}>{query.name}</div>
            <div style={{ "font-size": "12px", color: "var(--text-muted)", "margin-bottom": "8px" }}>{query.description}</div>
            <div style={{ display: "flex", gap: "6px", "align-items": "center", "flex-wrap": "wrap" }}>
              <For each={query.params}>
                {(p) => {
                  const inp = <input class="search-input" placeholder={p.name + (p.default ? ` (${p.default})` : "")}
                                     style={{ "max-width": "160px", padding: "6px 10px", "font-size": "12px" }} /> as HTMLInputElement;
                  inputs.set(p.name, inp);
                  return inp;
                }}
              </For>
              <button class="filter-pill active"
                      onClick={() => handleRun(query.name, query.params)}>
                Run
              </button>
            </div>
          </div>
        )}
      </For>

      <Show when={q().results}>
        <Show when={"error" in (q().results ?? {})} fallback={
          <Show when={q().results && "rows" in (q().results ?? {}) && (q().results as { rows: unknown[] }).rows?.length}>
            <div class="card">
              <div class="card-header">
                <h3>{q().resultsName} {"\u2014"} {(q().results as { rows: unknown[] }).rows.length} rows</h3>
              </div>
              <table class="data-table">
                <thead>
                  <tr>
                    <For each={(q().results as { columns: string[] }).columns}>
                      {(c) => <th>{c}</th>}
                    </For>
                  </tr>
                </thead>
                <tbody>
                  <For each={(q().results as { rows: Record<string, unknown>[] }).rows}>
                    {(row) => (
                      <tr>
                        <For each={(q().results as { columns: string[] }).columns}>
                          {(c) => <td>{row[c] != null ? String(row[c]) : ""}</td>}
                        </For>
                      </tr>
                    )}
                  </For>
                </tbody>
              </table>
            </div>
          </Show>
        }>
          <p style={{ color: "var(--red)", padding: "8px" }}>{(q().results as { error: string }).error}</p>
        </Show>
      </Show>
    </div>
  );
}
