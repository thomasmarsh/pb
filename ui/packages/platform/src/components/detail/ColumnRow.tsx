// ColumnRow.tsx — Expandable table row showing a column's read/write lineage.

import { Show, For, createSignal } from "solid-js";
import { ChevronDown, ChevronRight, type ColumnDetail, type ColumnPsRef } from "@pb/platform";
import type { JSX } from "solid-js";
interface ColumnRowProps {
  col: ColumnDetail;
}

function PsRefList(props: { refs: ColumnPsRef[] }): JSX.Element {
  return (
    <Show when={props.refs.length > 0} fallback={<span style={{ color: "var(--text-muted)" }}>(none)</span>}>
      <For each={props.refs}>
        {(ref) => (
          <div>
            {ref.object}{ref.proc_name ? ` / ${ref.proc_name}` : ""} · {ref.operation}
          </div>
        )}
      </For>
    </Show>
  );
}

export function ColumnRow(props: ColumnRowProps): JSX.Element {
  const [expanded, setExpanded] = createSignal(false);
  const col = props.col;

  return (
    <>
      <tr class="clickable" onClick={() => setExpanded(!expanded())}>
        <td class="name-cell">{expanded() ? <ChevronDown size={12} /> : <ChevronRight size={12} />} {col.column}</td>
        <td>{col.dw_readers.length} DW{col.dw_readers.length !== 1 ? "s" : ""}</td>
        <td>{col.ps_readers.length} PS read{col.ps_readers.length !== 1 ? "s" : ""}</td>
        <td>{col.ps_writers.length} PS write{col.ps_writers.length !== 1 ? "s" : ""}</td>
      </tr>
      <Show when={expanded()}>
        <tr>
          <td colspan="4" style={{ padding: "8px 16px", background: "var(--bg-secondary)" }}>
            <div style={{ "margin-bottom": "6px" }}>
              <strong>DW readers:</strong>{" "}
              <Show when={col.dw_readers.length > 0} fallback={<span style={{ color: "var(--text-muted)" }}>(none)</span>}>
                {col.dw_readers.join("  ")}
              </Show>
            </div>
            <div style={{ "margin-bottom": "6px" }}>
              <strong>PS readers:</strong>
              <PsRefList refs={col.ps_readers} />
            </div>
            <div>
              <strong>PS writers:</strong>
              <PsRefList refs={col.ps_writers} />
            </div>
          </td>
        </tr>
      </Show>
    </>
  );
}
