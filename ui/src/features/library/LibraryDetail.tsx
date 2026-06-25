// LibraryDetail.tsx — Library detail: object list always visible with summary section below.

import { Show, For, createResource } from "solid-js";
import { Package } from "../../utils/icons.js";
import type { Store } from "@pb/core";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import type { LibraryDetailResponse } from "../../types/api.js";
import { EntityCard } from "../../components/detail/EntityCard.js";
import { Loading } from "../../components/ui/Loading.js";

export function LibraryDetail(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const route = () => snap().nav.route;
  const libName = () => {
    const r = route();
    return r.view === "libraryDetail" ? r.name : "";
  };

  const [data] = createResource(
    libName,
    (name) =>
      fetch(`/api/libraries/${encodeURIComponent(name)}`)
        .then((r) => {
          if (!r.ok) throw new Error(`${r.status}`);
          return r.json() as Promise<LibraryDetailResponse>;
        }),
  );

  function navigate(name: string, kind: string): void {
    if (kind === "datawindow") {
      store.dispatch({ tag: "datawindows", action: { tag: "select", name } });
    } else {
      store.dispatch({ tag: "objects", action: { tag: "select", name } });
    }
  }

  function navigateToDead(): void {
    store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "deadCode" } } });
  }

  return (
    <div class="card">
      <div class="card-header">
        <h2><span class="entity-icon"><Package size={16} /></span> {libName()}</h2>
      </div>

      <Show when={data.loading}>
        <Loading />
      </Show>

      <Show when={data.error}>
        <div class="error-banner">Failed to load library: {String(data.error)}</div>
      </Show>

      <Show when={data()}>
        {(lib) => (
          <>
            <div style={{ "margin-bottom": "8px", color: "var(--text-muted)", "font-size": "13px" }}>
              {lib().object_count} objects
            </div>
            <table class="data-table">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Kind</th>
                  <th>Procs</th>
                </tr>
              </thead>
              <tbody>
                <For each={lib().objects}>
                  {(obj) => (
                    <tr>
                      <td class="name-cell">
                        <EntityCard
                          type={obj.kind === "datawindow" ? "datawindow" : "object"}
                          name={obj.name}
                          onClick={() => navigate(obj.name, obj.kind)}
                        />
                      </td>
                      <td>
                        <span class={`badge ${obj.kind === "datawindow" ? "badge-dw" : obj.kind === "powerscript" ? "badge-ps" : "badge-proj"}`}>
                          {obj.kind}
                        </span>
                      </td>
                      <td>{obj.proc_count}</td>
                    </tr>
                  )}
                </For>
              </tbody>
            </table>

            <div style={{ "margin-top": "16px", "border-top": "1px solid var(--border)", "padding-top": "12px" }}>
              <table class="data-table">
                <tbody>
                  <tr>
                    <td>Total procedures</td>
                    <td>{lib().objects.reduce((s, o) => s + o.proc_count, 0)}</td>
                  </tr>
                  <tr>
                    <td>Uncalled procedures</td>
                    <td>
                      <button class="link-btn" onClick={navigateToDead}>
                        {lib().uncalled_proc_count}
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </>
        )}
      </Show>
    </div>
  );
}
