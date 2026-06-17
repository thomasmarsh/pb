// Queries.tsx — SQL queries view.

import { Show, For, onMount, createSignal } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import { SqlBlock } from "../../components/CodeBlock.js";

type ParamDef = { name: string; type: string; default: string | null };

export function Queries(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const q = () => snap().queries;
  const [paramValues, setParamValues] = createSignal<Record<string, string>>({});
  const [shownSql, setShownSql] = createSignal<Set<string>>(new Set());
  const [showErrors, setShowErrors] = createSignal<Set<string>>(new Set());

  function handleParamInput(queryName: string, paramName: string, value: string) {
    setParamValues(prev => ({ ...prev, [`${queryName}.${paramName}`]: value }));
    if (showErrors().has(queryName)) {
      setShowErrors(prev => { const next = new Set(prev); next.delete(queryName); return next; });
    }
  }

  function requiredMissing(query: { name: string; params: ParamDef[] }): string[] {
    const vals = paramValues();
    return query.params
      .filter(p => p.default === null && !(vals[`${query.name}.${p.name}`] ?? "").trim())
      .map(p => p.name);
  }

  function toggleSql(name: string) {
    setShownSql(prev => {
      const next = new Set(prev);
      if (next.has(name)) next.delete(name); else next.add(name);
      return next;
    });
  }

  onMount(() => {
    store.dispatch({ tag: "nav", action: { type: "navigate", route: { view: "queries" } } });
    if (!q().items.length) store.dispatch({ tag: "queries", action: { type: "load" } });
  });

  function attemptRun(query: { name: string; params: ParamDef[] }) {
    const missing = requiredMissing(query);
    if (missing.length > 0) {
      setShowErrors(prev => new Set(prev).add(query.name));
      return;
    }
    const bound: Record<string, string> = {};
    const vals = paramValues();
    for (const p of query.params) {
      const v = vals[`${query.name}.${p.name}`];
      if (v) bound[p.name] = v;
      else if (p.default) bound[p.name] = p.default;
    }
    store.dispatch({ tag: "queries", action: { type: "run", name: query.name, params: bound } });
  }

  return (
    <div class="card">
      <div class="card-header"><h2>SQL Queries</h2></div>

      <For each={q().items}>
        {(query) => {
          const missing = () => requiredMissing(query);
          const isDisabled = () => missing().length > 0;
          return (
            <div style={{ "margin-bottom": "16px", "padding-bottom": "16px", "border-bottom": "1px solid var(--border)" }}>
              <div style={{ "font-weight": "600", "margin-bottom": "4px" }}>{query.name}</div>
              <div style={{ "font-size": "12px", color: "var(--text-muted)", "margin-bottom": "8px" }}>{query.description}</div>
              <div style={{ display: "flex", gap: "6px", "align-items": "center", "flex-wrap": "wrap" }}>
                <For each={query.params}>
                  {(p) => (
                    <input class="search-input"
                           placeholder={p.name + (p.default ? ` (${p.default})` : "")}
                           style={{
                             "max-width": "160px",
                             padding: "6px 10px",
                             "font-size": "12px",
                             ...(p.default === null && showErrors().has(query.name) && !(paramValues()[p.name] ?? "").trim()
                               ? { border: "1px solid var(--red)", "box-shadow": "0 0 0 1px var(--red)" }
                               : {}),
                           }}
                           onInput={(e) => handleParamInput(query.name, p.name, e.currentTarget.value)}
                           onKeyDown={(e) => { if (e.key === "Enter") attemptRun(query); }} />
                  )}
                </For>
                <button class="filter-pill active"
                        disabled={isDisabled()}
                        data-query={query.name}
                        onClick={() => attemptRun(query)}>
                  Run
                </button>
                <Show when={query.sql}>
                  <button class="filter-pill" onClick={() => toggleSql(query.name)}>
                    {shownSql().has(query.name) ? "Hide SQL" : "SQL"}
                  </button>
                </Show>
              </div>
              <Show when={showErrors().has(query.name) && missing().length > 0}>
                <div style={{ color: "var(--red)", "font-size": "12px", "margin-top": "4px" }}>
                  Required: {missing().join(", ")}
                </div>
              </Show>
              <Show when={shownSql().has(query.name) && query.sql}>
                <SqlBlock code={query.sql!} style={{ "margin-top": "8px", "font-size": "11px" }} />
              </Show>
            </div>
          );
        }}
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
