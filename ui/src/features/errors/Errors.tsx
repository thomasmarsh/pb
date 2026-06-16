// Errors.tsx — Parse/ingestion error browser: list + raw/anonymized detail.

import { For, Show, onMount } from "solid-js";
import { Tabs } from "@kobalte/core/tabs";
import { useSnapshot } from "../../core/store.js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import type { ErrorKindFilter } from "./types.js";
import type { ParseErrorRow } from "../../types/api.js";
import { CodeBlock } from "../../components/CodeBlock.js";
import { CopyButton } from "../../components/CopyButton.js";
import { anonymizeText } from "../../core/anonymize.js";

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
        </tbody>
      </table>
      <div style={{ "font-size": "11px", color: "var(--text-muted)", "margin-top": "8px" }}>
        {e().total} error(s)
      </div>

      <Show when={e().selected}>
        {(() => {
          const row = e().selected!;
          const baseLine = row.error_kind === "sql" ? (row.line ?? 1) : 1;
          return (
            <div class="card" style={{ "margin-top": "16px" }}>
              <Tabs defaultValue="raw">
                <Tabs.List class="tab-bar">
                  <Tabs.Trigger value="raw" class="tab-btn">Raw</Tabs.Trigger>
                  <Tabs.Trigger value="anonymized" class="tab-btn">Anonymized</Tabs.Trigger>
                </Tabs.List>

                <Tabs.Content value="raw">
                  <div class="error-detail-header">
                    <p>{row.message}</p>
                    <CopyButton text={row.snippet ?? row.message} />
                  </div>
                  <Show when={row.snippet}>
                    <CodeBlock code={row.snippet!} baseLine={baseLine} highlightLine={row.line ?? undefined} />
                  </Show>
                </Tabs.Content>

                <Tabs.Content value="anonymized">
                  <div class="error-detail-header">
                    <p>{anonymizeText(row.message)}</p>
                    <CopyButton text={anonymizeText(row.snippet ?? row.message)} />
                  </div>
                  <Show when={row.snippet}>
                    <CodeBlock code={anonymizeText(row.snippet!)} baseLine={baseLine} highlightLine={row.line ?? undefined} />
                  </Show>
                </Tabs.Content>
              </Tabs>
            </div>
          );
        })()}
      </Show>
    </div>
  );
}
