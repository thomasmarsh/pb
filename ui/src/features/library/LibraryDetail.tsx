// LibraryDetail.tsx — Library detail: object list (source) + metrics (analysis).

import { Show, For, createResource, createSignal } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import type { LibraryDetailResponse } from "../../types/api.js";
import { FaceToggle, type Face } from "../../components/FaceToggle.js";
import { EntityCard } from "../../components/EntityCard.js";
import { PhaseGateInline } from "../../components/PhaseGate.js";
import { Loading } from "../../components/Loading.js";

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

  const [face, setFace] = createSignal<Face>("source");

  function navigate(name: string): void {
    store.dispatch({ tag: "objects", action: { tag: "select", name } });
  }

  function navigateToDead(): void {
    store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "deadCode" } } });
  }

  return (
    <div class="card">
      <div class="card-header">
        <h2><span class="entity-icon">◆</span> {libName()}</h2>
        <FaceToggle face={face()} phaseLabel="P1 only" onToggle={(f) => setFace(f)} />
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
            <Show when={face() === "source"}>
              <div style={{ "margin-bottom": "8px", color: "var(--text-muted)", "font-size": "13px" }}>
                {lib().object_count} objects
              </div>
              <div class="entity-card-list">
                <For each={lib().objects}>
                  {(obj) => (
                    <EntityCard
                      type={obj.kind === "datawindow" ? "datawindow" : "object"}
                      name={obj.name}
                      context={`${obj.kind} · ${obj.proc_count} procs`}
                      onClick={() => navigate(obj.name)}
                    />
                  )}
                </For>
              </div>
            </Show>

            <Show when={face() === "analysis"}>
              <table class="data-table">
                <tbody>
                  <tr>
                    <td>Objects</td>
                    <td>{lib().object_count}</td>
                  </tr>
                  <tr>
                    <td>Total procedures</td>
                    <td>
                      {lib().objects.reduce((s, o) => s + o.proc_count, 0)}
                    </td>
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
              <PhaseGateInline
                phase={3}
                section="Inter-library dependencies"
                label="requires context-sensitive call graph"
                description="A full inter-library dependency graph requires the P3 context-sensitive analysis pass."
              />
            </Show>
          </>
        )}
      </Show>
    </div>
  );
}
