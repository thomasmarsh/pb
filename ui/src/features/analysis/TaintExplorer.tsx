// features/analysis/TaintExplorer.tsx — Taint Explorer: filterable list of P3 taint paths.

import { Show, For, createResource, createSignal } from "solid-js";
import type { JSX } from "solid-js";
import { ArrowRight } from "../../utils/icons.js";
import type { Store } from "@pb/core";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import type { TaintPathsResponse, TaintPathSummary } from "../../types/api.js";
import { Loading } from "../../components/ui/Loading.js";

const SEVERITY_ORDER: Record<string, number> = { critical: 0, high: 1, medium: 2, low: 3 };

export function TaintExplorer(props: { store: Store<AppState, AppAction> }): JSX.Element {
  const [sourceType, setSourceType] = createSignal("");
  const [sinkType,   setSinkType]   = createSignal("");
  const [severity,   setSeverity]   = createSignal("");

  const key = () => `${sourceType()}|${sinkType()}|${severity()}`;

  const [data] = createResource(key, async (): Promise<TaintPathsResponse> => {
    const params = new URLSearchParams();
    if (sourceType()) params.set("source_type", sourceType());
    if (sinkType())   params.set("sink_type",   sinkType());
    if (severity())   params.set("severity",     severity());
    const res = await fetch("/api/analysis/taint-paths?" + params.toString());
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json() as Promise<TaintPathsResponse>;
  });

  function openPath(id: number): void {
    props.store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "taintPathView", pathId: id } } });
  }

  const sorted = (): TaintPathSummary[] => {
    const paths = data()?.paths ?? [];
    return [...paths].sort((a, b) =>
      (SEVERITY_ORDER[a.severity] ?? 9) - (SEVERITY_ORDER[b.severity] ?? 9)
    );
  };

  return (
    <div class="card">
      <div class="card-header">
        <h2>Taint Explorer</h2>
      </div>

      {/* Filters */}
      <div class="taint-filters">
        <label class="taint-filter-label">
          Source type
          <select
            class="taint-filter-select"
            value={sourceType()}
            onInput={(e) => setSourceType(e.currentTarget.value)}
          >
            <option value="">All</option>
            <option value="db_read">DB read</option>
            <option value="request_param">Request param</option>
          </select>
        </label>
        <label class="taint-filter-label">
          Sink type
          <select
            class="taint-filter-select"
            value={sinkType()}
            onInput={(e) => setSinkType(e.currentTarget.value)}
          >
            <option value="">All</option>
            <option value="db_write">DB write</option>
            <option value="exec_immediate">EXECUTE IMMEDIATE</option>
          </select>
        </label>
        <label class="taint-filter-label">
          Severity
          <select
            class="taint-filter-select"
            value={severity()}
            onInput={(e) => setSeverity(e.currentTarget.value)}
          >
            <option value="">All</option>
            <option value="critical">Critical</option>
            <option value="high">High</option>
            <option value="medium">Medium</option>
            <option value="low">Low</option>
          </select>
        </label>
      </div>

      <Show when={data.loading}>
        <Loading />
      </Show>

      <Show when={data.error}>
        <div class="error-banner">Failed to load taint paths: {String(data.error)}</div>
      </Show>

      <Show when={!data.loading && !data.error && data()}>
        <div style={{ "margin-bottom": "8px", color: "var(--text-muted)", "font-size": "13px" }}>
          {data()!.total} path{data()!.total === 1 ? "" : "s"} found
        </div>

        <Show
          when={sorted().length > 0}
          fallback={
            <div class="taint-empty">
              No taint paths found under current filters.
              <br />
              This does not constitute a formal proof of absence — P4 formal verification is required for that guarantee.
            </div>
          }
        >
          <table class="data-table taint-path-table">
            <thead>
              <tr>
                <th>Severity</th>
                <th>Category</th>
                <th>Source</th>
                <th>Sink</th>
                <th>Steps</th>
              </tr>
            </thead>
            <tbody>
              <For each={sorted()}>
                {(path) => (
                  <tr class="clickable" onClick={() => openPath(path.id)}>
                    <td>
                      <span class={`badge badge-severity-${path.severity}`}>{path.severity}</span>
                    </td>
                    <td>{path.category}</td>
                    <td class="taint-endpoint">
                      <span class="taint-proc">{path.source.object}.{path.source.proc}</span>
                      <Show when={path.source.line != null}>
                        <span class="taint-line">:{path.source.line}</span>
                      </Show>
                      <span class="taint-type-label">{path.source.type}</span>
                    </td>
                    <td class="taint-endpoint">
                      <span class="taint-proc">{path.sink.object}.{path.sink.proc}</span>
                      <Show when={path.sink.line != null}>
                        <span class="taint-line">:{path.sink.line}</span>
                      </Show>
                      <span class="taint-type-label">{path.sink.type}</span>
                    </td>
                    <td>
                      <span class="trace-nav-link">View <ArrowRight size={12} style={{ "vertical-align": "middle" }} /></span>
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
