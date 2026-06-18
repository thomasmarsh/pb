// DeadCode.tsx — Dead Code report: uncalled procedures (P1).

import { Show, For, createResource } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import type { DeadCodeResponse } from "../../types/api.js";
import { EntityCard } from "../../components/EntityCard.js";
import { PhaseGateInline } from "../../components/PhaseGate.js";
import { Loading } from "../../components/Loading.js";

export function DeadCode(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;

  const [data] = createResource<DeadCodeResponse>(
    () =>
      fetch("/api/analysis/dead-code")
        .then((r) => {
          if (!r.ok) throw new Error(`${r.status}`);
          return r.json() as Promise<DeadCodeResponse>;
        }),
  );

  function navigateToProc(objectName: string, procName: string): void {
    store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName, procName } });
  }

  // Group items by object name.
  const grouped = () => {
    const result: { object: string; items: DeadCodeResponse["items"] }[] = [];
    const seen = new Map<string, number>();
    for (const item of data()?.items ?? []) {
      const idx = seen.get(item.object);
      if (idx === undefined) {
        seen.set(item.object, result.length);
        result.push({ object: item.object, items: [item] });
      } else {
        result[idx]!.items.push(item);
      }
    }
    return result;
  };

  return (
    <div class="card">
      <div class="card-header">
        <h2>Dead Code Report</h2>
      </div>

      <Show when={data.loading}>
        <Loading />
      </Show>

      <Show when={data.error}>
        <div class="error-banner">Failed to load: {String(data.error)}</div>
      </Show>

      <Show when={data() && !data.loading}>
        <div style={{ "margin-bottom": "12px", color: "var(--text-muted)", "font-size": "13px" }}>
          {data()!.total} uncalled procedure{data()!.total === 1 ? "" : "s"} (caller count = 0)
        </div>

        <For each={grouped()}>
          {(group) => (
            <div style={{ "margin-bottom": "16px" }}>
              <div class="section-label" style={{ "margin-bottom": "4px" }}>{group.object}</div>
              <div class="entity-card-list">
                <For each={group.items}>
                  {(item) => (
                    <EntityCard
                      type="procedure"
                      name={item.name}
                      context={`${item.proc_type}${item.cyclomatic != null ? ` · cc=${item.cyclomatic}` : ""}`}
                      onClick={() => navigateToProc(item.object, item.name)}
                    />
                  )}
                </For>
              </div>
            </div>
          )}
        </For>

        <Show when={data()!.total === 0}>
          <div style={{ color: "var(--text-muted)", "font-size": "13px" }}>
            No uncalled procedures found.
          </div>
        </Show>
      </Show>

      <PhaseGateInline
        phase={2}
        section="Unreachable Branches"
        label="requires typing pass"
        description="Unreachable branch detection uses the P2 control-flow graph and type information."
      />
      <PhaseGateInline
        phase={4}
        section="Proven Dead"
        label="requires formal analysis"
        description="Formally proven dead code requires the P4 Z3 solver integration."
      />
    </div>
  );
}
