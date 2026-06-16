// ProceduresCard.tsx — Procedures table for an object.

import { For } from "solid-js";
import type { Store } from "../../../core/store.js";
import type { AppState } from "../../../app/state.js";
import type { AppAction } from "../../../app/actions.js";
import type { ProcedureInfo } from "../../../types/api.js";
import { procBadge } from "../../../utils/format.js";

export function ProceduresCard(props: {
  store: Store<AppState, AppAction>;
  objectName: string;
  procedures: ProcedureInfo[];
}) {
  return (
    <div class="card">
      <div class="card-header"><h3>Procedures ({props.procedures.length})</h3></div>
      <table class="data-table">
        <thead>
          <tr><th>Name</th><th>Type</th><th>Modifiers</th><th>Params</th><th>CC</th><th>Lines</th></tr>
        </thead>
        <tbody>
          <For each={props.procedures}>
            {(p) => (
              <tr class="clickable"
                  onClick={() => props.store.dispatch({ tag: "objects", action: { type: "proc-select", objectName: props.objectName, procName: p.name } })}>
                <td class="name-cell">{p.name}</td>
                <td><span class={`badge ${procBadge(p.proc_type)}`}>{p.proc_type}</span></td>
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
  );
}
