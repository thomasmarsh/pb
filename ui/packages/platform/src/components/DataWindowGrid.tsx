// DataWindowGrid.tsx — Table-based grid renderer for DataWindow mock data.

import { For, Show } from "solid-js";

export interface DWRow {
  [column: string]: unknown;
}

export interface DataWindowGridProps {
  data: DWRow[];
  columns?: string[];
  onCellClick?: (row: number, column: string, value: unknown) => void;
}

export function DataWindowGrid(props: DataWindowGridProps) {
  const columns = () =>
    props.columns || (props.data.length > 0 ? Object.keys(props.data[0]!) : []);

  return (
    <div class="dw-grid-container" style={{ "overflow-x": "auto" }}>
      <Show
        when={props.data.length > 0}
        fallback={<div style={{ padding: "8px", color: "var(--text-muted)", "font-size": "12px" }}>No data</div>}
      >
        <table class="data-table" style={{ "font-size": "12px", width: "100%" }}>
          <thead>
            <tr>
              <For each={columns()}>
                {(col) => <th style={{ "text-align": "left", padding: "4px 8px" }}>{col}</th>}
              </For>
            </tr>
          </thead>
          <tbody>
            <For each={props.data}>
              {(row, rowIndex) => (
                <tr>
                  <For each={columns()}>
                    {(col) => (
                      <td
                        style={{ padding: "4px 8px", cursor: props.onCellClick ? "pointer" : undefined }}
                        onClick={() => props.onCellClick?.(rowIndex(), col, row[col])}
                      >
                        {String(row[col] ?? "")}
                      </td>
                    )}
                  </For>
                </tr>
              )}
            </For>
          </tbody>
        </table>
      </Show>
    </div>
  );
}
