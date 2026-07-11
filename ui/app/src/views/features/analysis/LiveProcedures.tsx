// LiveProcedures.tsx — Live Procedures report (Plan 161 Phase 4): procedures
// the Souffle live_proc IDB confirms reachable and not dead.

import { Show, For, onMount } from "solid-js";
import { Code2 } from "@pb/platform";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";

export function LiveProcedures(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();

  onMount(() => {
    store.dispatch({ tag: "analysis", action: { tag: "load-live-procedures" } });
  });

  return (
    <div class="card">
      <div class="card-header" style={{ display: "flex", "align-items": "center", gap: "8px" }}>
        <h2 style={{ flex: 1 }}>Live Procedures</h2>
        <Show when={snap().analysis.liveProceduresLoaded}>
          <span style={{ color: "var(--text-muted)", "font-size": "13px" }}>
            {snap().analysis.liveProcedures.length} procedure{snap().analysis.liveProcedures.length === 1 ? "" : "s"}
          </span>
        </Show>
      </div>

      <Show when={!snap().analysis.liveProceduresLoaded}>
        <div style={{ color: "var(--text-muted)", "font-size": "13px", padding: "8px 0" }}>Loading…</div>
      </Show>

      <Show when={snap().analysis.liveProceduresLoaded}>
        <Show when={snap().analysis.liveProcedures.length === 0}>
          <div style={{ color: "var(--text-muted)", "font-size": "13px", padding: "8px 0" }}>
            No SQL-touching procedures confirmed live.
          </div>
        </Show>

        <Show when={snap().analysis.liveProcedures.length > 0}>
          <table class="data-table" style={{ "font-size": "13px" }}>
            <thead>
              <tr>
                <th>Object</th>
                <th>Procedure</th>
              </tr>
            </thead>
            <tbody>
              <For each={snap().analysis.liveProcedures}>
                {(item) => (
                  <tr
                    class="clickable"
                    onClick={() => store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: item.object, procName: item.proc_name } })}
                  >
                    <td style={{ color: "var(--text-muted)", "font-size": "12px" }}>{item.object}</td>
                    <td>
                      <span class="entity-card-icon" style={{ "margin-right": "4px" }}><Code2 size={13} /></span>
                      {item.proc_name}
                    </td>
                  </tr>
                )}
              </For>
            </tbody>
          </table>
        </Show>
      </Show>
    </div>
  );
}
