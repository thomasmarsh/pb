// DWList.tsx — DataWindows list with search and keyboard navigation.

import { Show, For, onMount } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import { EntityCard } from "../../components/detail/EntityCard.js";
import { shortFile } from "@pb/platform";
import { Loading } from "../../components/ui/Loading.js";
import { useListKeyboard } from "../../utils/hooks/useListKeyboard.js";

export function DWList(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const dw = () => snap().datawindows;

  onMount(() => {
    if (dw().items.length === 0) {
      store.dispatch({ tag: "datawindows", action: { tag: "search", q: dw().q } });
    }
  });

  useListKeyboard({
    items: () => dw().items.map((item) => ({
      select: () => store.dispatch({ tag: "datawindows", action: { tag: "select", name: item.name } }),
    })),
    tableSelector: ".dw-list-table",
  });

  return (
    <>
      <div class="search-bar">
        <input
          class="search-input"
          type="text"
          placeholder="Search DataWindows…"
          value={dw().q}
          onInput={(e) => store.dispatch({ tag: "datawindows", action: { tag: "search", q: e.currentTarget.value } })}
        />
      </div>

      <Show when={!dw().loading || dw().items.length > 0} fallback={<Loading />}>
        <div class="card">
          <div class="card-header">
            <h2>{dw().q ? `DataWindows — ${dw().total} results` : `DataWindows (${dw().total})`}</h2>
          </div>
          <table class="data-table dw-list-table">
            <thead><tr><th>Name</th><th>File</th></tr></thead>
            <tbody>
              <For each={dw().items}>
                {(d) => (
                  <tr>
                    <td class="name-cell" style={{ padding: "4px 8px" }}>
                      <EntityCard
                        type="datawindow"
                        name={d.name}
                        onClick={() => store.dispatch({ tag: "datawindows", action: { tag: "select", name: d.name } })}
                      />
                    </td>
                    <td style={{ "font-size": "11px", color: "var(--text-muted)" }}>{shortFile(d.file)}</td>
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
