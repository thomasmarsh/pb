// features/analysis/ColumnAffinityCore.tsx — Embeddable column-affinity panel
// (Plan 153 D3): per-table column x statement co-access heat matrix + the
// average-linkage dendrogram computed over it, i.e. which column blocks
// travel together and are latent-entity decomposition candidates.
//
// Data flows through the tables feature's env/reducer (CLAUDE.md Rule 1/2),
// mirroring DecompositionCandidatesCore.tsx — not a self-fetching component.

import { Show, For, createMemo, onMount } from "solid-js";
import type { JSX } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";

export interface ColumnAffinityCoreProps {
  store: Store<AppState, AppAction>;
  table: string;
}

// Sequential single-hue scale (dataviz skill: magnitude -> one hue, light to
// dark) mixed off the app's own --accent token rather than a hardcoded ramp,
// so it tracks the active theme automatically. Count is always shown as the
// cell's own text, so the "table view" accessibility fallback is satisfied
// by construction — the numbers ARE the table.
function cellStyle(count: number, max: number): JSX.CSSProperties {
  const pct = max > 0 ? Math.round((count / max) * 85) : 0;
  return {
    "background-color": `color-mix(in srgb, var(--accent) ${pct}%, var(--bg-card))`,
    "text-align": "center",
    padding: "4px 6px",
    "font-variant-numeric": "tabular-nums",
  };
}

function HeatMatrix(props: { columns: string[]; matrix: number[][] }): JSX.Element {
  const max = createMemo(() => props.matrix.reduce((m, row) => row.reduce((mm, v) => Math.max(mm, v), m), 0));

  return (
    <table class="data-table" style={{ "font-size": "12px" }}>
      <thead>
        <tr>
          <th />
          <For each={props.columns}>{(c) => <th style={{ "text-align": "center" }}>{c}</th>}</For>
        </tr>
      </thead>
      <tbody>
        <For each={props.columns}>
          {(rowCol, i) => (
            <tr>
              <th style={{ "text-align": "left", padding: "4px 8px" }}>{rowCol}</th>
              <For each={props.matrix[i()]}>
                {(count) => <td style={cellStyle(count, max())}>{count}</td>}
              </For>
            </tr>
          )}
        </For>
      </tbody>
    </table>
  );
}

function DendrogramList(props: { merges: { similarity: number; members: string[] }[] }): JSX.Element {
  return (
    <ul style={{ margin: "8px 0 0 0", "padding-left": "16px", "font-size": "12px" }}>
      <For each={props.merges}>
        {(m) => (
          <li>
            {m.members.join(", ")} <span style={{ color: "var(--text-muted)" }}>(similarity {m.similarity.toFixed(3)})</span>
          </li>
        )}
      </For>
    </ul>
  );
}

export function ColumnAffinityCore(props: ColumnAffinityCoreProps): JSX.Element {
  const snap = props.store.getState();

  onMount(() => {
    props.store.dispatch({
      tag: "tables",
      action: { tag: "column-affinity-load", tableName: props.table },
    });
  });

  const entry = createMemo(() => snap().tables.columnAffinity);
  const loading = createMemo(() => snap().tables.columnAffinityLoading);

  const current = createMemo(() => {
    const e = entry();
    if (!e || "error" in e) return null;
    if (e.table !== props.table) return null;
    return e;
  });

  return (
    <>
      <Show when={loading() && !current()}>
        <div style={{ padding: "8px 0" }}>
          <div class="loading-overlay"><div class="spinner" /> Loading column affinity…</div>
        </div>
      </Show>
      <Show when={!loading() && entry() && "error" in entry()!}>
        <div class="error-banner">
          Failed to load column affinity: {(entry() as { error: string }).error}
        </div>
      </Show>
      <Show when={current()}>
        {(data) => (
          <Show
            when={data().columns.length > 0}
            fallback={
              <div style={{ padding: "8px 0", color: "var(--text-muted)", "font-size": "13px" }}>
                No column affinity data for this table.
              </div>
            }
          >
            <HeatMatrix columns={data().columns} matrix={data().co_access_matrix} />
            <DendrogramList merges={data().dendrogram} />
          </Show>
        )}
      </Show>
    </>
  );
}
