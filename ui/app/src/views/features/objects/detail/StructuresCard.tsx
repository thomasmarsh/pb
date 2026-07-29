// StructuresCard.tsx — Inline structures owned by this object, one field
// table per structure. Structure fields aren't independently navigable, so
// this is presentational only (no store/dispatch), unlike ProceduresCard.

import { For } from "solid-js";
import type { StructureInfo } from "@pb/platform";

export function StructuresCard(props: { structures: StructureInfo[] }) {
  return (
    <div class="card">
      <div class="card-header"><h3>Structures ({props.structures.length})</h3></div>
      <For each={props.structures}>
        {(s) => (
          <div style={{ "margin-bottom": "12px" }}>
            <div style={{ "font-size": "11px", color: "var(--text-muted)", "font-weight": 600, "margin-bottom": "4px", "padding": "0 4px", "text-transform": "uppercase", "letter-spacing": "0.05em" }}>
              {s.name} ({s.fields.length})
            </div>
            <table class="data-table">
              <thead>
                <tr><th>Field</th><th>Type</th><th>Modifiers</th></tr>
              </thead>
              <tbody>
                <For each={s.fields} fallback={
                  <tr><td colspan="3" style={{ color: "var(--text-muted)", padding: "8px" }}>No fields.</td></tr>
                }>
                  {(f) => (
                    <tr>
                      <td class="name-cell">{f.var_name}</td>
                      <td style={{ "font-size": "12px" }}>{f.var_type}</td>
                      <td style={{ "font-size": "12px" }}>{f.modifiers ?? ""}</td>
                    </tr>
                  )}
                </For>
              </tbody>
            </table>
          </div>
        )}
      </For>
    </div>
  );
}
