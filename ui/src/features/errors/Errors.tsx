// Errors.tsx — Parse/ingestion error browser: list + raw/anonymized detail.

import { For, Show, createMemo, createResource, onMount } from "solid-js";
import { Tabs } from "@kobalte/core/tabs";
import { useSnapshot } from "../../core/store.js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import type { ErrorKindFilter } from "./types.js";
import { PAGE_SIZE } from "./types.js";
import type { ParseErrorRow } from "../../types/api.js";
import { CodeBlock } from "../../components/CodeBlock.js";
import { CopyButton } from "../../components/CopyButton.js";
import { anonymizeText } from "../../core/anonymize.js";
import { highlightAsync } from "../../lib/highlight.js";

const KIND_FILTERS: { value: ErrorKindFilter; label: string }[] = [
  { value: "all", label: "All" },
  { value: "powerscript", label: "PowerScript / Lex" },
  { value: "sql", label: "SQL" },
];

export function Errors(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = useSnapshot(store.state);
  const e = () => snap().errors;

  onMount(() => {
    store.dispatch({ tag: "nav", action: { type: "navigate", route: { view: "errors" } } });
    store.dispatch({ tag: "errors", action: { type: "load" } });
  });

  function select(row: ParseErrorRow) {
    store.dispatch({ tag: "errors", action: { type: "select", row } });
  }

  const totalPages = () => Math.max(1, Math.ceil(e().total / PAGE_SIZE));

  return (
    <div class="card">
      <div class="card-header"><h2>Parse Errors</h2></div>

      <div class="filter-pills">
        <For each={KIND_FILTERS}>
          {(f) => (
            <button
              class={`filter-pill ${e().filterKind === f.value ? "active" : ""}`}
              onClick={() => store.dispatch({ tag: "errors", action: { type: "setFilterKind", kind: f.value } })}
            >
              {f.label}
            </button>
          )}
        </For>
        <input
          class="search-input"
          placeholder="Search message / file / snippet"
          value={e().query}
          onInput={(ev) => store.dispatch({ tag: "errors", action: { type: "setQuery", query: ev.currentTarget.value } })}
        />
      </div>

      <table class="data-table">
        <thead>
          <tr>
            <th>File</th>
            <th>Kind</th>
            <th>Line</th>
            <th>Message</th>
          </tr>
        </thead>
        <tbody>
          <Show when={!e().loading}>
            <For each={e().items}>
              {(row) => (
                <tr class="error-list-item" onClick={() => select(row)}>
                  <td class="name-cell">{row.file}</td>
                  <td>{row.error_kind}</td>
                  <td>{row.line ?? ""}</td>
                  <td>{row.message}</td>
                </tr>
              )}
            </For>
          </Show>
        </tbody>
      </table>

      <Show when={e().loading}>
        <div style={{ "text-align": "center", padding: "12px", color: "var(--text-muted)" }}>Loading...</div>
      </Show>

      <Show when={e().total > PAGE_SIZE}>
        <div class="pagination" style={{ "display": "flex", "gap": "8px", "align-items": "center", "justify-content": "center", "margin-top": "8px" }}>
          <button
            class="filter-pill"
            disabled={e().page === 0}
            onClick={() => store.dispatch({ tag: "errors", action: { type: "setPage", page: e().page - 1 } })}
          >Prev</button>
          <span style={{ "font-size": "12px", color: "var(--text-muted)" }}>
            Page {e().page + 1} of {totalPages()} ({e().total} total)
          </span>
          <button
            class="filter-pill"
            disabled={e().page >= totalPages() - 1}
            onClick={() => store.dispatch({ tag: "errors", action: { type: "setPage", page: e().page + 1 } })}
          >Next</button>
        </div>
      </Show>

      <Show when={e().total > 0 && !e().loading}>
        <div style={{ "font-size": "11px", color: "var(--text-muted)", "margin-top": "8px" }}>
          {e().total} error(s)
        </div>
      </Show>

      <Show when={e().selected}>
        {(() => {
          const row = e().selected!;
          const baseLine = row.error_kind === "sql" ? (row.line ?? 1) : 1;
          const rawSnippet = () => row.snippet ?? row.message;
          const anonSnippet = createMemo(() => anonymizeText(rawSnippet()));
          const anonMessage = createMemo(() => anonymizeText(row.message));

          const isSql = row.error_kind === "sql";

          return (
            <div class="card" style={{ "margin-top": "16px" }}>
              <Tabs defaultValue="raw">
                <Tabs.List class="tab-bar">
                  <Tabs.Trigger value="raw" class="tab-btn">Raw</Tabs.Trigger>
                  <Tabs.Trigger value="anonymized" class="tab-btn">Anonymized</Tabs.Trigger>
                  {isSql && <Tabs.Trigger value="file-context" class="tab-btn">File Context</Tabs.Trigger>}
                </Tabs.List>

                <Tabs.Content value="raw">
                  <div class="error-detail-header">
                    <p>{row.message}</p>
                    <CopyButton text={rawSnippet()} />
                  </div>
                  <Show when={row.snippet}>
                    <CodeBlock code={row.snippet!} baseLine={baseLine} highlightLine={row.line ?? undefined} />
                  </Show>
                </Tabs.Content>

                <Tabs.Content value="anonymized">
                  <div class="error-detail-header">
                    <p>{anonMessage()}</p>
                    <CopyButton text={anonSnippet()} />
                  </div>
                  <Show when={row.snippet}>
                    <CodeBlock code={anonSnippet()} baseLine={baseLine} highlightLine={row.line ?? undefined} />
                  </Show>
                </Tabs.Content>

                {isSql && (
                  <Tabs.Content value="file-context">
                    <ErrorFileContext row={row} />
                  </Tabs.Content>
                )}
              </Tabs>
            </div>
          );
        })()}
      </Show>
    </div>
  );
}

function ErrorFileContext(props: { row: ParseErrorRow }) {
  const [raw] = createResource(
    () => props.row.file,
    (file) => fetch("/api/errors/source?file=" + encodeURIComponent(file))
      .then(r => r.json() as Promise<{ lines: string[] }>),
    { initialValue: { lines: [] as string[] } },
  );

  const [highlighted] = createResource(
    () => raw()?.lines,
    (lines) => {
      if (!lines || lines.length === 0) return Promise.resolve("");
      return highlightAsync(lines.join("\n"));
    },
    { initialValue: "" },
  );

  const line = () => props.row.line ?? 1;

  return (
    <div>
      <div class="error-detail-header">
        <p>Full file source — error at line {line()}</p>
      </div>
      <Show
        when={!highlighted.loading && highlighted()}
        fallback={<div class="loading-overlay"><div class="spinner" /> Loading file source...</div>}
      >
        <CodeBlock code={highlighted()!} baseLine={1} highlightLine={line()} />
      </Show>
    </div>
  );
}
