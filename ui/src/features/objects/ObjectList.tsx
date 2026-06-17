// ObjectList.tsx — Object listing with search, filters, and pagination.

import { Show, For } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import { shortFile } from "../../utils/format.js";
import { Loading } from "../../components/Loading.js";

export function ObjectList(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const os = () => snap().objects;

  return (
    <>
      <div class="search-bar">
        <input
          class="search-input"
          type="text"
          placeholder="Search objects..."
          value={os().q}
          onInput={(e) => store.dispatch({ tag: "objects", action: { type: "search", q: e.currentTarget.value } })}
        />
      </div>

      <div class="filter-pills">
        <For each={["", "powerscript", "datawindow", "project", "pipeline"]}>
          {(k) => (
            <button
              class={`filter-pill${os().kind === k ? " active" : ""}`}
              onClick={() => store.dispatch({ tag: "objects", action: { type: "filter-kind", kind: k } })}
            >
              {k || "All"}
            </button>
          )}
        </For>
      </div>

      <Show when={!os().loading || os().items.length > 0} fallback={<Loading />}>
        <div class="card">
          <div class="card-header"><h2>Objects ({os().total})</h2></div>
          <table class="data-table">
            <thead>
              <tr>
                <th class={os().sort === "name" ? "sorted" : ""}
                    onClick={() => store.dispatch({ tag: "objects", action: { type: "sort", col: "name" } })}>
                  Name{os().sort === "name" ? (os().order === "asc" ? " ▲" : " ▼") : ""}
                </th>
                <th class={os().sort === "kind" ? "sorted" : ""}
                    onClick={() => store.dispatch({ tag: "objects", action: { type: "sort", col: "kind" } })}>
                  Kind{os().sort === "kind" ? (os().order === "asc" ? " ▲" : " ▼") : ""}
                </th>
                <th>File</th><th>Ancestor</th>
              </tr>
            </thead>
            <tbody>
              <For each={os().items}>
                {(obj) => {
                  const bc = obj.kind === "powerscript" ? "ps" : obj.kind === "datawindow" ? "dw" : "proj";
                  return (
                    <tr class="clickable"
                        onClick={() => store.dispatch({ tag: "objects", action: { type: "select", name: obj.name } })}>
                      <td class="name-cell">{obj.name}</td>
                      <td><span class={`badge badge-${bc}`}>{obj.kind}</span></td>
                      <td style={{ "font-size": "11px", color: "var(--text-muted)", "max-width": "300px", overflow: "hidden", "text-overflow": "ellipsis", "white-space": "nowrap" }}>
                        {shortFile(obj.file)}
                      </td>
                      <td>{obj.ancestor ?? ""}</td>
                    </tr>
                  );
                }}
              </For>
            </tbody>
          </table>

          <Show when={os().total > 100}>
            <div style={{ display: "flex", gap: "8px", "margin-top": "12px", "justify-content": "center" }}>
              <Show when={os().offset > 0}>
                <button class="filter-pill"
                    onClick={() => store.dispatch({ tag: "objects", action: { type: "page", offset: Math.max(0, os().offset - 100) } })}>
                  ← Previous
                </button>
              </Show>
              <span style={{ color: "var(--text-muted)", "font-size": "12px", padding: "4px 8px" }}>
                {os().offset + 1}–{Math.min(os().offset + 100, os().total)} of {os().total}
              </span>
              <Show when={os().offset + 100 < os().total}>
                <button class="filter-pill"
                    onClick={() => store.dispatch({ tag: "objects", action: { type: "page", offset: os().offset + 100 } })}>
                  Next →
                </button>
              </Show>
            </div>
          </Show>
        </div>
      </Show>
    </>
  );
}
