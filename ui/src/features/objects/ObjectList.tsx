// ObjectList.tsx — Object listing with search, filters, and pagination.

import { Show, For, onMount } from "solid-js";
import { ChevronUp, ChevronDown, ArrowUpDown } from "../../utils/icons.js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import { EntityCard } from "../../components/detail/EntityCard.js";
import { shortFile } from "../../utils/format.js";
import { Loading } from "../../components/ui/Loading.js";
import { Pagination } from "../../components/ui/Pagination.js";
import { useListKeyboard } from "../../utils/hooks/useListKeyboard.js";

export function ObjectList(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const os = () => snap().objects;

  onMount(() => {
    if (os().items.length === 0) {
      store.dispatch({ tag: "objects", action: { tag: "search", q: os().q } });
    }
  });

  useListKeyboard({
    items: () => os().items.map((obj) => ({
      select: () => store.dispatch({ tag: "objects", action: { tag: "select", name: obj.name } }),
    })),
    tableSelector: ".object-list-table",
  });

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
          onInput={(e) => store.dispatch({ tag: "objects", action: { tag: "search", q: e.currentTarget.value } })}
        />
      </div>

      <div class="filter-pills">
        <For each={["", "powerscript", "datawindow", "project", "pipeline"]}>
          {(k) => (
            <button
              class={`filter-pill${os().kind === k ? " active" : ""}`}
              onClick={() => store.dispatch({ tag: "objects", action: { tag: "filter-kind", kind: k } })}
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
                    onClick={() => store.dispatch({ tag: "objects", action: { tag: "sort", col: "name" } })}>
                  Name{" "}
                  {os().sort === "name" ? (os().order === "asc" ? <ChevronUp size={11} style={{"vertical-align":"middle"}} /> : <ChevronDown size={11} style={{"vertical-align":"middle"}} />) : <ArrowUpDown size={11} style={{"vertical-align":"middle", opacity:"0.3"}} />}
                </th>
                <th class={os().sort === "kind" ? "sorted" : ""}
                    onClick={() => store.dispatch({ tag: "objects", action: { tag: "sort", col: "kind" } })}>
                  Kind{" "}
                  {os().sort === "kind" ? (os().order === "asc" ? <ChevronUp size={11} style={{"vertical-align":"middle"}} /> : <ChevronDown size={11} style={{"vertical-align":"middle"}} />) : <ArrowUpDown size={11} style={{"vertical-align":"middle", opacity:"0.3"}} />}
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
                          onClick={() => store.dispatch({ tag: "objects", action: { tag: "select", name: obj.name } })}
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
            <Pagination
              page={Math.floor(os().offset / 100)}
              totalPages={Math.ceil(os().total / 100)}
              total={os().total}
              pageSize={100}
              onPageChange={(p) => store.dispatch({ tag: "objects", action: { tag: "page", offset: p * 100 } })}
            />
          </Show>
        </div>
      </Show>
    </>
  );
}
