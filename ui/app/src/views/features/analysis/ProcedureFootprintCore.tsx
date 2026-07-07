// features/analysis/ProcedureFootprintCore.tsx — Embeddable procedure-footprint
// panel (Plan 153 D6): which tables/columns a procedure reads and writes.
//
// Data flows through the objects feature's env/reducer (CLAUDE.md Rule 1/2),
// mirroring WiringCore.tsx — not a self-fetching component like the legacy
// CFGCore.tsx/ProcTaintCard, which predate the AppEnv architecture.

import { Show, For, createMemo, onMount } from "solid-js";
import type { JSX } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";
import { TableChip } from "../../components/detail/TableChip.js";

export interface ProcedureFootprintCoreProps {
  store: Store<AppState, AppAction>;
  object: string;
  proc: string;
}

export function ProcedureFootprintCore(props: ProcedureFootprintCoreProps): JSX.Element {
  const snap = props.store.getState();

  onMount(() => {
    props.store.dispatch({
      tag: "objects",
      action: { tag: "footprint-load", objectName: props.object, procName: props.proc },
    });
  });

  const entry = createMemo(() => snap().objects.procedureFootprint);
  const loading = createMemo(() => snap().objects.procedureFootprintLoading);

  const current = createMemo(() => {
    const e = entry();
    if (!e || "error" in e) return null;
    if (e.object !== props.object || e.proc_name !== props.proc) return null;
    return e;
  });

  return (
    <>
      <Show when={loading() && !current()}>
        <div style={{ padding: "8px 0" }}>
          <div class="loading-overlay"><div class="spinner" /> Loading footprint…</div>
        </div>
      </Show>
      <Show when={!loading() && entry() && "error" in entry()!}>
        <div class="error-banner">
          Failed to load procedure footprint: {(entry() as { error: string }).error}
        </div>
      </Show>
      <Show when={current()}>
        {(data) => (
          <Show
            when={data().statements.length > 0 || data().unresolved.length > 0}
            fallback={
              <div style={{ padding: "8px 0", color: "var(--text-muted)", "font-size": "13px" }}>
                No table/column footprint found for this procedure.
              </div>
            }
          >
            <Show when={data().statements.length > 0}>
              <table class="data-table" style={{ "font-size": "12px" }}>
                <thead>
                  <tr>
                    <th>Line</th>
                    <th>Table</th>
                    <th>Column</th>
                    <th>Mode</th>
                  </tr>
                </thead>
                <tbody>
                  <For each={data().statements}>
                    {(stmt) => (
                      <For each={stmt.columns}>
                        {(col) => (
                          <tr>
                            <td>{stmt.line}</td>
                            <td><TableChip name={col.table} store={props.store} size="sm" /></td>
                            <td>{col.column}</td>
                            <td>
                              <span class={col.is_write ? "badge badge-cc" : "badge badge-ps"}>
                                {col.is_write ? "write" : "read"}
                              </span>
                            </td>
                          </tr>
                        )}
                      </For>
                    )}
                  </For>
                </tbody>
              </table>
            </Show>
            <Show when={data().unresolved.length > 0}>
              <div style={{ "margin-top": "12px" }}>
                <div style={{ "font-size": "12px", color: "var(--text-muted)", "margin-bottom": "4px" }}>
                  Unresolved references:
                </div>
                <table class="data-table" style={{ "font-size": "12px" }}>
                  <thead>
                    <tr>
                      <th>Line</th>
                      <th>Reference</th>
                    </tr>
                  </thead>
                  <tbody>
                    <For each={data().unresolved}>
                      {(u) => (
                        <tr>
                          <td>{u.line}</td>
                          <td>{u.raw_name}</td>
                        </tr>
                      )}
                    </For>
                  </tbody>
                </table>
              </div>
            </Show>
          </Show>
        )}
      </Show>
    </>
  );
}
