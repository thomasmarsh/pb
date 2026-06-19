// Queries.tsx — Ask surface: free-text NL/SQL input + predefined SQL query catalogue.

import { Show, For, onMount, createSignal } from "solid-js";
import { ChevronUp, ChevronDown, ChevronLeft, ChevronRight, ArrowUpDown } from "../../utils/icons.js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import { SqlBlock } from "../../components/detail/CodeBlock.js";
import { EntityCard } from "../../components/detail/EntityCard.js";
import type { EntityType } from "../../components/detail/EntityCard.js";
import type { QueryColumn } from "../../types/api.js";

const PAGE_SIZE = 50;

type ParamDef = { name: string; type: string; default: string | null };

const ENTITY_TYPE_MAP: Record<string, EntityType> = {
  object:     "object",
  procedure:  "procedure",
  datawindow: "datawindow",
  table:      "table",
};

export function Queries(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const q = () => snap().queries;

  const [paramValues, setParamValues] = createSignal<Record<string, string>>({});
  const [shownSql, setShownSql] = createSignal<Set<string>>(new Set());
  const [showErrors, setShowErrors] = createSignal<Set<string>>(new Set());

  onMount(() => {
    if (!q().items.length) store.dispatch({ tag: "queries", action: { tag: "load" } });
  });

  // ── Predefined query helpers ───────────────────────────────────────────────

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
    store.dispatch({ tag: "queries", action: { tag: "run", name: query.name, params: bound } });
  }

  function toggleSql(name: string) {
    setShownSql(prev => {
      const next = new Set(prev);
      if (next.has(name)) next.delete(name); else next.add(name);
      return next;
    });
  }

  // ── AskInput: free-text textarea ──────────────────────────────────────────

  function handleAskKeyDown(e: KeyboardEvent) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      store.dispatch({ tag: "queries", action: { tag: "submit-ask" } });
    }
  }

  const queryPaneLabel = () => q().isSqlMode ? "SQL query" : "generated query";

  // ── Sorted + paged row helpers ─────────────────────────────────────────────

  function sortedRows(): Record<string, unknown>[] {
    const state = q();
    const results = state.results;
    if (!results || "error" in results || !("rows" in results)) return [];
    const rows = (results as { rows: Record<string, unknown>[] }).rows;
    if (!state.sortCol) return rows;
    const col = state.sortCol;
    const dir = state.sortDir;
    return [...rows].sort((a, b) => {
      const cmp = String(a[col] ?? "").localeCompare(String(b[col] ?? ""), undefined, { numeric: true });
      return dir === "asc" ? cmp : -cmp;
    });
  }

  function pagedRows() {
    const page = q().page;
    return sortedRows().slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);
  }

  function totalPages() {
    return Math.max(1, Math.ceil(sortedRows().length / PAGE_SIZE));
  }

  function handleEntityClick(col: QueryColumn, row: Record<string, unknown>) {
    const entityName = String(row[col.name] ?? "");
    const results = q().results;
    const columns: QueryColumn[] = (results && "columns" in results) ? (results as { columns: QueryColumn[] }).columns : [];
    const objectCol = columns.find(c => c.entity_type === "object");
    const objectName = objectCol ? String(row[objectCol.name] ?? "") : null;
    store.dispatch({
      tag: "queries",
      action: { tag: "navigate-to-entity", entityType: col.entity_type!, entityName, objectName },
    });
  }

  function renderCell(col: QueryColumn, row: Record<string, unknown>) {
    const val = row[col.name];
    const display = val != null ? String(val) : "";
    const entityType = display && col.entity_type ? ENTITY_TYPE_MAP[col.entity_type] : null;
    if (entityType) {
      return (
        <td>
          <EntityCard
            type={entityType}
            name={display}
            onClick={() => handleEntityClick(col, row)}
          />
        </td>
      );
    }
    return <td>{display}</td>;
  }

  const hasResults = () => {
    const r = q().results;
    return !!(r && "rows" in r && (r as { rows: unknown[] }).rows?.length);
  };

  return (
    <div class="card">
      <div class="card-header"><h2>Ask</h2></div>

      {/* ── AskInput ─────────────────────────────────────────────────────── */}
      <div style={{ padding: "12px 16px", "border-bottom": "1px solid var(--border)" }}>
        <div style={{ display: "flex", gap: "8px", "align-items": "flex-start" }}>
          <textarea
            class="search-input"
            placeholder="Ask pb anything… or start with SELECT to write SQL directly."
            rows={2}
            disabled={q().loading}
            value={q().askText}
            style={{ flex: "1", resize: "vertical", "min-height": "40px", padding: "8px 10px", "font-size": "13px", "font-family": "inherit" }}
            onInput={(e) => store.dispatch({ tag: "queries", action: { tag: "set-ask-text", text: e.currentTarget.value } })}
            onKeyDown={handleAskKeyDown}
          />
          <button
            class="filter-pill active"
            disabled={q().loading || !q().askText.trim()}
            style={{ "white-space": "nowrap", "align-self": "flex-end" }}
            onClick={() => store.dispatch({ tag: "queries", action: { tag: "submit-ask" } })}
          >
            {q().loading ? "Running…" : "Ask"}
          </button>
        </div>

        {/* Generated query toggle */}
        <Show when={q().generatedSql !== null}>
          <div style={{ "margin-top": "6px" }}>
            <button
              class="filter-pill"
              style={{ "font-size": "11px" }}
              onClick={() => store.dispatch({ tag: "queries", action: { tag: "toggle-query-pane" } })}
            >
              {q().queryPaneOpen ? <><ChevronUp size={12} /> Hide {queryPaneLabel()}</> : <><ChevronDown size={12} /> Show {queryPaneLabel()}</>}
            </button>
          </div>
        </Show>

        {/* Expandable generated-query pane */}
        <Show when={q().queryPaneOpen && q().generatedSql !== null}>
          <div style={{ "margin-top": "8px", border: "1px solid var(--border)", "border-radius": "4px", overflow: "hidden" }}>
            <div style={{ display: "flex", "justify-content": "space-between", "align-items": "center", padding: "4px 8px", background: "var(--bg-secondary)", "font-size": "11px", color: "var(--text-muted)" }}>
              <span>{q().isSqlMode ? "SQL Query" : "Generated Query"}</span>
              <button
                class="filter-pill active"
                style={{ "font-size": "11px", padding: "2px 8px" }}
                onClick={() => {
                  const sql = q().generatedSql;
                  if (sql) store.dispatch({ tag: "queries", action: { tag: "run-sql", sql } });
                }}
              >
                Run
              </button>
            </div>
            <textarea
              style={{ width: "100%", "min-height": "80px", padding: "8px", "font-family": "monospace", "font-size": "12px", background: "var(--bg-code)", color: "var(--text)", border: "none", resize: "vertical", "box-sizing": "border-box" }}
              value={q().generatedSql ?? ""}
              onInput={(e) => store.dispatch({ tag: "queries", action: { tag: "set-generated-sql", sql: e.currentTarget.value } })}
            />
          </div>
        </Show>

        {/* Recent queries strip */}
        <Show when={q().recentQueries.length > 0 && !q().askText.trim()}>
          <div style={{ display: "flex", gap: "6px", "margin-top": "8px", "flex-wrap": "wrap", "align-items": "center" }}>
            <span style={{ "font-size": "11px", color: "var(--text-muted)", "white-space": "nowrap" }}>Recent:</span>
            <For each={q().recentQueries}>
              {(text) => (
                <button
                  class="filter-pill"
                  style={{ "font-size": "11px", "max-width": "220px", overflow: "hidden", "text-overflow": "ellipsis", "white-space": "nowrap" }}
                  title={text}
                  onClick={() => store.dispatch({ tag: "queries", action: { tag: "run-recent", text } })}
                >
                  {text.length > 40 ? text.slice(0, 40) + "…" : text}
                </button>
              )}
            </For>
          </div>
        </Show>
      </div>

      {/* ── Predefined SQL query catalogue ─────────────────────────────────── */}
      <Show when={q().items.length > 0}>
        <div style={{ padding: "8px 16px 0", "font-size": "11px", "font-weight": "600", color: "var(--text-muted)", "text-transform": "uppercase", "letter-spacing": "0.05em" }}>
          SQL Queries
        </div>
        <For each={q().items}>
          {(query) => {
            const missing = () => requiredMissing(query);
            const isDisabled = () => missing().length > 0;
            return (
              <div style={{ margin: "8px 16px", "padding-bottom": "12px", "border-bottom": "1px solid var(--border)" }}>
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
                               ...(p.default === null && showErrors().has(query.name) && !(paramValues()[`${query.name}.${p.name}`] ?? "").trim()
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
      </Show>

      {/* ── Results ─────────────────────────────────────────────────────────── */}
      <Show when={q().results}>
        <Show when={"error" in (q().results ?? {})} fallback={
          <Show when={hasResults()}>
            <div class="card" style={{ margin: "12px 16px 0" }}>
              <div class="card-header">
                <h3>{q().resultsName} — {(q().results as { rows: unknown[] }).rows.length} rows</h3>
              </div>
              <table class="data-table">
                <thead>
                  <tr>
                    <For each={(q().results as { columns: QueryColumn[] }).columns}>
                      {(col) => (
                        <th
                          style={{ cursor: "pointer", "user-select": "none" }}
                          onClick={() => store.dispatch({ tag: "queries", action: { tag: "sort", col: col.name } })}
                        >
                          {col.name}
                          {" "}
                          <Show when={q().sortCol === col.name}
                            fallback={<ArrowUpDown size={11} style={{ opacity: "0.3", "vertical-align": "middle" }} />}
                          >
                            {q().sortDir === "asc" ? <ChevronUp size={11} style={{ "vertical-align": "middle" }} /> : <ChevronDown size={11} style={{ "vertical-align": "middle" }} />}
                          </Show>
                        </th>
                      )}
                    </For>
                  </tr>
                </thead>
                <tbody>
                  <For each={pagedRows()}>
                    {(row) => (
                      <tr>
                        <For each={(q().results as { columns: QueryColumn[] }).columns}>
                          {(col) => renderCell(col, row)}
                        </For>
                      </tr>
                    )}
                  </For>
                </tbody>
              </table>
              <Show when={totalPages() > 1}>
                <div style={{ display: "flex", gap: "8px", padding: "8px", "align-items": "center", "font-size": "12px" }}>
                  <button class="filter-pill"
                          disabled={q().page === 0}
                          onClick={() => store.dispatch({ tag: "queries", action: { tag: "set-page", page: q().page - 1 } })}>
                    <ChevronLeft size={13} /> Prev
                  </button>
                  <span>Page {q().page + 1} of {totalPages()}</span>
                  <button class="filter-pill"
                          disabled={q().page >= totalPages() - 1}
                          onClick={() => store.dispatch({ tag: "queries", action: { tag: "set-page", page: q().page + 1 } })}>
                    Next <ChevronRight size={13} />
                  </button>
                </div>
              </Show>
            </div>
          </Show>
        }>
          <p style={{ color: "var(--red)", padding: "8px 16px" }}>{(q().results as { error: string }).error}</p>
        </Show>
      </Show>
    </div>
  );
}
