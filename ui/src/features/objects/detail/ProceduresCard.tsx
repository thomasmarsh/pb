// ProceduresCard.tsx — Procedures grouped by kind (functions / events / subroutines).

import { For, Show } from "solid-js";
import type { Store } from "../../../core/store.js";
import type { AppState } from "../../../features/app/state.js";
import type { AppAction } from "../../../features/app/actions.js";
import type { ProcedureInfo } from "../../../types/api.js";

const KIND_GROUPS: { label: string; match: (t: string) => boolean }[] = [
  { label: "Functions",   match: (t) => t === "function" },
  { label: "Events",      match: (t) => t === "event" },
  { label: "Subroutines", match: (t) => t === "subroutine" || t === "on" },
];

function ProcGroup(props: {
  label: string;
  procs: ProcedureInfo[];
  objectName: string;
  store: Store<AppState, AppAction>;
}) {
  return (
    <Show when={props.procs.length > 0}>
      <div style={{ "margin-bottom": "12px" }}>
        <div style={{ "font-size": "11px", color: "var(--text-muted)", "font-weight": 600, "margin-bottom": "4px", "padding": "0 4px", "text-transform": "uppercase", "letter-spacing": "0.05em" }}>
          {props.label} ({props.procs.length})
        </div>
        <table class="data-table">
          <thead>
            <tr><th>Name</th><th>Modifiers</th><th>Params</th><th>CC</th><th>Lines</th></tr>
          </thead>
          <tbody>
            <For each={props.procs}>
              {(p) => (
                <tr class="clickable"
                    onClick={() => props.store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: props.objectName, procName: p.name } })}>
                  <td class="name-cell">{p.name}</td>
                  <td style={{ "font-size": "12px" }}>{p.modifiers ?? ""}</td>
                  <td style={{ "font-size": "12px", "max-width": "200px", overflow: "hidden", "text-overflow": "ellipsis", "white-space": "nowrap" }}>{p.params ?? ""}</td>
                  <td>{p.cyclomatic != null ? <span class="badge badge-cc">{String(p.cyclomatic)}</span> : "–"}</td>
                  <td style={{ "font-size": "12px", color: "var(--text-muted)" }}>
                    {p.start_line && p.end_line ? `${p.start_line}–${p.end_line}` : "–"}
                  </td>
                </tr>
              )}
            </For>
          </tbody>
        </table>
      </div>
    </Show>
  );
}

export function ProceduresCard(props: {
  store: Store<AppState, AppAction>;
  objectName: string;
  procedures: ProcedureInfo[];
}) {
  return (
    <div class="card">
      <div class="card-header"><h3>Procedures ({props.procedures.length})</h3></div>
      <For each={KIND_GROUPS}>
        {(group) => (
          <ProcGroup
            label={group.label}
            procs={props.procedures.filter((p) => group.match(p.proc_type))}
            objectName={props.objectName}
            store={props.store}
          />
        )}
      </For>
    </div>
  );
}
