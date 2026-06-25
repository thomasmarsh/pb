// MetricsGrid.tsx — Metric cards for an object detail.

import { For } from "solid-js";

interface Metrics {
  in_degree?: number | null;
  out_degree?: number | null;
  max_cyclomatic?: number | null;
  avg_cyclomatic?: number | null;
  pagerank?: number | null;
  dit?: number | null;
}

export function MetricsGrid(props: { metrics: Metrics }) {
  return (
    <div class="metric-grid">
      <For each={[
        ["In Degree", props.metrics.in_degree],
        ["Out Degree", props.metrics.out_degree],
        ["Max CC", props.metrics.max_cyclomatic],
        ["Avg CC", props.metrics.avg_cyclomatic ? parseFloat(String(props.metrics.avg_cyclomatic)).toFixed(1) : "–"],
        ["PageRank", props.metrics.pagerank ? parseFloat(String(props.metrics.pagerank)).toFixed(4) : "–"],
        ["DIT", props.metrics.dit ?? "–"],
      ] as [string, string | number | null | undefined][]}>
        {([l, v]) => (
          <div class="metric-card">
            <div class="label">{l}</div>
            <div class="value">{String(v ?? "–")}</div>
          </div>
        )}
      </For>
    </div>
  );
}
