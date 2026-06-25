// components/GlobalSearch.tsx — Keyboard-triggered search overlay.

import { Show, For, createEffect } from "solid-js";
import { Dynamic } from "solid-js/web";
import { Search, Clock } from "../utils/icons.js";
import type { JSX } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../features/app/state.js";
import type { AppAction } from "../features/app/actions.js";
import { procBadge, shortFile } from "../utils/format.js";
import { entityIcon } from "../utils/entities.js";
import { debounce } from "../utils/debounce.js";
import { ModalShell } from "./ui/ModalShell.js";

export function GlobalSearch(props: { store: Store<AppState, AppAction> }): JSX.Element {
  const store = props.store;
  const snap = store.getState();
  const se = () => snap().search;

  let inputRef: HTMLInputElement | undefined;

  createEffect(() => {
    if (se().overlayOpen && inputRef) {
      inputRef.focus();
    }
  });

  const doSearch = debounce((val: string) => {
    store.dispatch({ tag: "search", action: { tag: "overlay-term", term: val } });
  }, 250);

  function close(): void {
    store.dispatch({ tag: "search", action: { tag: "overlay-close" } });
  }

  function navigateAndClose(dispatchFn: () => void): void {
    dispatchFn();
    close();
  }

  const results = () => se().overlayResults;
  const recent  = () => se().recentSearches;
  const term    = () => se().overlayTerm;

  const hasResults = () => {
    const r = results();
    if (!r) return false;
    return r.objects.length + r.procedures.length + r.datawindows.length + (r.tables?.length ?? 0) > 0;
  };

  return (
    <ModalShell open={se().overlayOpen} onClose={close} label="Search">
      <div class="gs-input-row">
        <span class="gs-input-icon" aria-hidden="true"><Search size={16} /></span>
        <input
          ref={inputRef}
          class="gs-input"
          placeholder="Search objects, procedures, DataWindows, tables…"
          value={term()}
          onInput={(e) => doSearch(e.currentTarget.value)}
          onKeyDown={(e) => { if (e.key === "Escape") close(); }}
        />
        <button class="gs-close-btn" onClick={close} aria-label="Close search">×</button>
      </div>

      <Show when={term().length < 2 && recent().length > 0}>
        <div class="gs-section">
          <div class="gs-section-header">Recent</div>
          <For each={recent()}>
            {(q) => (
              <button class="gs-recent-item" onClick={() => {
                store.dispatch({ tag: "search", action: { tag: "overlay-term", term: q } });
              }}>
                <span class="gs-recent-icon" aria-hidden="true"><Clock size={14} /></span>
                {q}
              </button>
            )}
          </For>
        </div>
      </Show>

      <Show when={se().overlayLoading}>
        <div class="gs-loading">Searching…</div>
      </Show>

      <Show when={term().length >= 2 && !se().overlayLoading && results() && !hasResults()}>
        <div class="gs-empty">No results for <em>{term()}</em></div>
      </Show>

      <Show when={hasResults()}>
        <div class="gs-results">
          <Show when={(results()?.objects.length ?? 0) > 0}>
            <div class="gs-section">
              <div class="gs-section-header">Objects</div>
              <For each={results()!.objects.slice(0, 8)}>
                {(o) => (
                  <button class="gs-result-item" onClick={() => navigateAndClose(() =>
                    store.dispatch({ tag: "objects", action: { tag: "select", name: o.name } })
                  )}>
                    <span class="gs-result-icon" aria-hidden="true"><Dynamic component={entityIcon(o.kind)} size={14} /></span>
                    <span class="gs-result-name">{o.name}</span>
                    <span class="gs-result-meta">{shortFile(o.file)}</span>
                  </button>
                )}
              </For>
            </div>
          </Show>

          <Show when={(results()?.procedures.length ?? 0) > 0}>
            <div class="gs-section">
              <div class="gs-section-header">Procedures</div>
              <For each={results()!.procedures.slice(0, 8)}>
                {(p) => (
                  <button class="gs-result-item" onClick={() => navigateAndClose(() =>
                    store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: p.object, procName: p.name } })
                  )}>
                    <span class="gs-result-icon" aria-hidden="true"><Dynamic component={entityIcon("procedure")} size={14} /></span>
                    <span class="gs-result-name">{p.name}</span>
                    <span class="gs-result-meta">{p.object}</span>
                    <span class={`badge ${procBadge(p.proc_type)}`}>{p.proc_type}</span>
                  </button>
                )}
              </For>
            </div>
          </Show>

          <Show when={(results()?.datawindows.length ?? 0) > 0}>
            <div class="gs-section">
              <div class="gs-section-header">DataWindows</div>
              <For each={results()!.datawindows.slice(0, 8)}>
                {(d) => (
                  <button class="gs-result-item" onClick={() => navigateAndClose(() =>
                    store.dispatch({ tag: "datawindows", action: { tag: "select", name: d.dw_name } })
                  )}>
                    <span class="gs-result-icon" aria-hidden="true"><Dynamic component={entityIcon("datawindow")} size={14} /></span>
                    <span class="gs-result-name">{d.dw_name}</span>
                    <span class="gs-result-meta">{d.control_type ?? ""}</span>
                  </button>
                )}
              </For>
            </div>
          </Show>

          <Show when={(results()?.tables?.length ?? 0) > 0}>
            <div class="gs-section">
              <div class="gs-section-header">Tables</div>
              <For each={results()!.tables!.slice(0, 8)}>
                {(t) => (
                  <button class="gs-result-item" onClick={() => navigateAndClose(() =>
                    store.dispatch({ tag: "tables", action: { tag: "select", name: t.table_name } })
                  )}>
                    <span class="gs-result-icon" aria-hidden="true"><Dynamic component={entityIcon("table")} size={14} /></span>
                    <span class="gs-result-name">{t.table_name}</span>
                  </button>
                )}
              </For>
            </div>
          </Show>
        </div>
      </Show>

      <div class="gs-hint">
        <kbd>Esc</kbd> to close · <kbd>/</kbd> to open
      </div>
    </ModalShell>
  );
}
