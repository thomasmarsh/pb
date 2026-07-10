// features/analysis/ColumnAffinityCore.tsx — Column-affinity building blocks
// (Plan 153 D3): per-table column x statement co-access heat matrix + the
// average-linkage dendrogram computed over it, i.e. which column blocks
// travel together and are latent-entity decomposition candidates.
//
// Consolidation (2026-07-09): this used to be its own standalone panel
// alongside Decomposition Candidates and Co-update Rituals. All three showed
// up as separate top-level buttons on TableDetail, but Column Affinity and
// Co-update Rituals are supporting evidence FOR a decomposition candidate,
// not independent findings of their own — so they're folded into
// DecompositionCandidatesCore.tsx (table-wide heat matrix + dendrogram
// shown once as an overview, ritual evidence shown per candidate row). This
// file now only exports the shared rendering pieces (HeatMatrix,
// DendrogramList) and the worked example data those two consumers share.

import { For, createMemo } from "solid-js";
import type { JSX } from "solid-js";

export function HeatMatrix(props: { columns: string[]; matrix: number[][] }): JSX.Element {
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

export function DendrogramList(props: { merges: { similarity: number; members: string[] }[] }): JSX.Element {
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

// Fake worked example over a canonical employee table — no store, no API.
// Chosen to make the interesting case obvious: {name, email} and
// {salary, hire_date} each co-occur constantly (same UI form / same payroll
// batch touches both), dept_id/mgr_id are touched independently of either
// cluster, so the dendrogram merges the two natural pairs early and only
// joins the whole table together at low similarity.
// Exported so DecompositionCandidatesCore's explainer can build its own
// worked example from these (Plan 156 rollout, merged further 2026-07-09).
export const AFFINITY_EXAMPLE_COLUMNS = ["name", "email", "salary", "hire_date", "dept_id"];
export const AFFINITY_EXAMPLE_MATRIX = [
  [0, 26, 2, 2, 4],
  [26, 0, 2, 2, 4],
  [2, 2, 0, 24, 1],
  [2, 2, 24, 0, 1],
  [4, 4, 1, 1, 0],
];
export const AFFINITY_EXAMPLE_MERGES = [
  { similarity: 0.93, members: ["name", "email"] },
  { similarity: 0.89, members: ["salary", "hire_date"] },
  { similarity: 0.31, members: ["name", "email", "salary", "hire_date"] },
  { similarity: 0.12, members: ["name", "email", "salary", "hire_date", "dept_id"] },
];
