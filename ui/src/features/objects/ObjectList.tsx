// ObjectList.tsx — Object listing with search, filters, and pagination.

import { Show, For, onMount, onCleanup } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import { EntityCard } from "../../components/EntityCard.js";
import { shortFile } from "../../utils/format.js";
import { Loading } from "../../components/Loading.js";

export function ObjectList(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const os = () => snap().objects;
  let cursorIdx = -1;

  // Preserve state: only load if list is empty.
  onMount(() => {
    if (os().items.length === 0) {
      store.dispatch({ tag: "objects", action: { type: "search", q: os().q } });
    }
  });

  onMount(() => {
    function handleKey(e: KeyboardEvent): void {
      const t = e.target as HTMLElement;
      if (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable) return;
      const items = os().items;
      if (e.key === "j") {
        e.preventDefault();
        cursorIdx = Math.min(cursorIdx + 1, items.length - 1);
        highlightRow(cursorIdx);
      } else if (e.key === "k") {
        e.preventDefault();
        cursorIdx = Math.max(cursorIdx - 1, 0);
        highlightRow(cursorIdx);
      } else if (e.key === "Enter" && cursorIdx >= 0) {
        e.preventDefault();
        const obj = items[cursorIdx];
        if (obj) store.dispatch({ tag: "objects", action: { type: "select", name: obj.name } });
      }
    }
    document.addEventListener("keydown", handleKey);
    onCleanup(() => document.removeEventListener("keydown", handleKey));
  });

  function highlightRow(idx: number): void {
    const table = document.querySelector(".object-list-table");
    if (!table) return;
    table.querySelectorAll("tr.list-cursor").forEach((r) => r.classList.remove("list-cursor"));
    const rows = table.querySelectorAll("tbody tr");
    rows[idx]?.classList.add("list-cursor");
    (rows[idx] as HTMLElement)?.scrollIntoView?.({ block: "nearest" });
  }

  const headerLabel = () => {
    const q = os().q;
    const total = os().total;
    return q ? `Objects — ${total} results` : `Objects (${total})`;
  };

  return (
    <>
      <div class="search-bar">
        <input
          class="search-input"
          type="text"
          placeholder="Search objects…"
          value={os().q}
          onInput={(e) => {
            cursorIdx = -1;
            store.dispatch({ tag: "objects", action: { type: "search", q: e.currentTarget.value } });
          }}
        />
      </div>

      <div class="filter-pills">
        <For each={["", "powerscript", "datawindow", "project", "pipeline"]}>
          {(k) => (
            <button
              class={`filter-pill${os().kind === k ? " active" : ""}`}
              onClick={() => {
                cursorIdx = -1;
                store.dispatch({ tag: "objects", action: { type: "filter-kind", kind: k } });
              }}
            >
              {k || "All"}
            </button>
          )}
        </For>
      </div>

      <Show when={!os().loading || os().items.length > 0} fallback={<Loading />}>
        <div class="card">
          <div class="card-header"><h2>{headerLabel()}</h2></div>
          <table class="data-table object-list-table">
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
                  const entityType = obj.kind === "datawindow" ? "datawindow" : "object";
                  return (
                    <tr>
                      <td class="name-cell" style={{ padding: "4px 8px" }}>
                        <EntityCard
                          type={entityType}
                          name={obj.name}
                          onClick={() => store.dispatch({ tag: "objects", action: { type: "select", name: obj.name } })}
                        />
                      </td>
                      <td>
                        <span class={`badge badge-${obj.kind === "powerscript" ? "ps" : obj.kind === "datawindow" ? "dw" : "proj"}`}>
                          {obj.kind}
                        </span>
                      </td>
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
