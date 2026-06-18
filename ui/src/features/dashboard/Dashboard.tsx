// Dashboard.tsx — Dashboard view.

import { Show, For, createMemo, createResource } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import type { ProcedureRow, TableSummary } from "../../types/api.js";
import type { Route } from "../../features/navigation/types.js";
import { TableChip } from "../../components/TableChip.js";
import { procBadge } from "../../utils/format.js";
import { Loading } from "../../components/Loading.js";
import { InlineDiagram } from "../../components/InlineDiagram.js";

function ProcedureTable(props: { title: string; procs: ProcedureRow[]; store: Store<AppState, AppAction> }) {
  return (
    <div class="card">
      <div class="card-header"><h2>{props.title}</h2></div>
      <table class="data-table">
        <thead>
          <tr><th>Object</th><th>Procedure</th><th>Type</th><th>Cyclomatic</th></tr>
        </thead>
        <tbody>
          <For each={props.procs}>
            {(p) => (
              <tr class="clickable"
                  onClick={() => props.store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: p.object, procName: p.name } })}>
                <td class="name-cell">{p.object}</td>
                <td>{p.name}</td>
                <td><span class={`badge ${procBadge(p.proc_type)}`}>{p.proc_type}</span></td>
                <td>{p.cyclomatic != null ? <span class="badge badge-cc">{String(p.cyclomatic)}</span> : "–"}</td>
              </tr>
            )}
          </For>
        </tbody>
      </table>
    </div>
  );
}

function ObjectTable(props: { title: string; objs: { object: string; pagerank: number; in_degree: number; out_degree: number }[]; store: Store<AppState, AppAction> }) {
  return (
    <div class="card">
      <div class="card-header"><h2>{props.title}</h2></div>
      <table class="data-table">
        <thead>
          <tr><th>Object</th><th>PageRank</th><th>In</th><th>Out</th></tr>
        </thead>
        <tbody>
          <For each={props.objs}>
            {(p) => (
              <tr class="clickable"
                  onClick={() => props.store.dispatch({ tag: "objects", action: { tag: "select", name: p.object } })}>
                <td class="name-cell">{p.object}</td>
                <td>{String(p.pagerank)}</td>
                <td>{String(p.in_degree)}</td>
                <td>{String(p.out_degree)}</td>
              </tr>
            )}
          </For>
        </tbody>
      </table>
    </div>
  );
}

function TopTablesWidget(props: { store: Store<AppState, AppAction> }) {
  const [tables] = createResource<TableSummary[]>(() =>
    fetch("/api/tables").then((r) => r.json() as Promise<TableSummary[]>),
  );
  const top = () => (tables() ?? []).slice(0, 10);

  return (
    <Show when={top().length > 0}>
      <div class="card">
        <div class="card-header"><h2>Most-Referenced DB Tables</h2></div>
        <table class="data-table">
          <thead><tr><th>Table</th><th>DW refs</th><th>PS refs</th></tr></thead>
          <tbody>
            <For each={top()}>
              {(t) => (
                <tr>
                  <td><TableChip name={t.table_name} store={props.store} /></td>
                  <td style={{ color: "var(--text-muted)" }}>{String(t.dw_count)}</td>
                  <td style={{ color: "var(--text-muted)" }}>{String(t.ps_count)}</td>
                </tr>
              )}
            </For>
          </tbody>
        </table>
      </div>
    </Show>
  );
}

type PhaseStatus = "active" | "not-built";

interface PhaseHealthRowProps {
  phase:  "P1" | "P2" | "P3" | "P4";
  status: PhaseStatus;
  metric: string;
  route:  Route | null;
  store:  Store<AppState, AppAction>;
}

function PhaseHealthRow(props: PhaseHealthRowProps) {
  const navigate = () => {
    if (props.route) {
      props.store.dispatch({ tag: "nav", action: { tag: "navigate", route: props.route } });
    }
  };

  return (
    <div class="phase-health-row">
      <span class={`phase-badge ${props.status === "active" ? "phase-badge-active" : "phase-badge-gated"}`}>
        {props.phase}
      </span>
      <span class={props.status === "active" ? "badge-status-active" : "badge-status-notbuilt"}>
        {props.status === "active" ? "Active" : "Not built"}
      </span>
      <span class="phase-health-metric">{props.metric}</span>
      {props.route
        ? <button class="phase-health-link" onClick={navigate}>View →</button>
        : <span class="phase-health-link muted">—</span>
      }
    </div>
  );
}

function fmt(n: number | undefined): string {
  return n != null ? n.toLocaleString() : "–";
}

export function Dashboard(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();

  const s = () => snap().dashboard.stats;

  const dwCount = createMemo(() =>
    s()?.by_kind?.find((k) => k.kind === "datawindow")?.count ?? 0
  );

  const p1Metric = createMemo(() => {
    const stats = s();
    if (!stats) return "";
    const files = stats.files_indexed != null ? `${fmt(stats.files_indexed)} files · ` : "";
    return `${files}${fmt(stats.objects)} objects · ${fmt(stats.procedures)} procedures`;
  });

  const completeness = createMemo(() => {
    const stats = s();
    if (!stats) return null;
    const errCount = stats.parse_error_count ?? 0;
    const indexed  = stats.files_indexed;
    if (indexed == null) return null;
    if (errCount === 0) return `${fmt(indexed)} files indexed · all parsed cleanly`;
    return `${fmt(indexed)} files indexed · ${fmt(errCount)} file${errCount === 1 ? "" : "s"} with parse errors`;
  });

  const tiles = createMemo(() => [
    { label: "Objects",     value: fmt(s()?.objects),    route: { view: "objects" }       as Route },
    { label: "DataWindows", value: fmt(dwCount()),        route: { view: "datawindows" }   as Route },
    { label: "DB Tables",   value: fmt(s()?.tables),     route: { view: "tables" }        as Route },
    { label: "Procedures",  value: fmt(s()?.procedures), route: { view: "proceduresList" } as Route },
  ]);

  return (
    <Show when={s()} fallback={<Loading />}>

      {/* Linked entry tiles */}
      <div class="metric-grid">
        <For each={tiles()}>
          {(tile) => (
            <div class="metric-card linked"
                 role="button"
                 tabIndex={0}
                 onClick={() => store.dispatch({ tag: "nav", action: { tag: "navigate", route: tile.route } })}
                 onKeyDown={(e) => e.key === "Enter" && store.dispatch({ tag: "nav", action: { tag: "navigate", route: tile.route } })}>
              <div class="label">{tile.label}</div>
              <div class="value">{tile.value}</div>
            </div>
          )}
        </For>
      </div>

      {/* Completeness signal */}
      <Show when={completeness()}>
        <div class="completeness-row">{completeness()}</div>
      </Show>

      {/* Parse error banner */}
      <Show when={(s()?.parse_error_count ?? 0) > 0}>
        <div class="parse-error-banner">
          <span>⚠ {fmt(s()!.parse_error_count)} file{(s()!.parse_error_count ?? 1) === 1 ? "" : "s"} failed to parse</span>
          <button class="parse-error-banner-link"
                  onClick={() => store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "errors" } } })}>
            Diagnostics →
          </button>
        </div>
      </Show>

      {/* Phase health rows */}
      <div class="card" style={{ "margin-bottom": "16px" }}>
        <div class="card-header"><h2>Analysis Phases</h2></div>
        <div class="phase-health-rows">
          <PhaseHealthRow
            phase="P1" status="active"
            metric={p1Metric()}
            route={{ view: "deadCode" }}
            store={store}
          />
          <PhaseHealthRow
            phase="P2" status="not-built"
            metric="Typing pass — infer types, compute CFG, detect unreachable branches"
            route={null}
            store={store}
          />
          <PhaseHealthRow
            phase="P3" status="not-built"
            metric="Context-insensitive taint analysis"
            route={{ view: "taintExplorer" }}
            store={store}
          />
          <PhaseHealthRow
            phase="P4" status="not-built"
            metric="Formal verification and symbolic execution"
            route={{ view: "formalReports" }}
            store={store}
          />
        </div>
      </div>

      <div class="card">
        <div class="card-header">
          <h2>Complexity Heatmap</h2>
        </div>
        <InlineDiagram kind="heatmap" store={store} compact />
      </div>

      <Show when={s()!.by_kind && s()!.by_kind!.length > 0}>
        <div class="card">
          <div class="card-header"><h2>Object Types</h2></div>
          <table class="data-table">
            <thead><tr><th>Kind</th><th>Count</th></tr></thead>
            <tbody>
              <For each={s()!.by_kind!}>
                {(k: { kind: string; count: number }) => {
                  const bc = k.kind === "powerscript" ? "ps" : k.kind === "datawindow" ? "dw" : "proj";
                  return (
                    <tr>
                      <td class="name-cell"><span class={`badge badge-${bc}`}>{k.kind}</span></td>
                      <td>{String(k.count)}</td>
                    </tr>
                  );
                }}
              </For>
            </tbody>
          </table>
        </div>
      </Show>

      <Show when={s()!.top_complex && s()!.top_complex!.length > 0}>
        <ProcedureTable title="Most Complex Procedures" procs={s()!.top_complex!} store={store} />
      </Show>

      <Show when={s()!.top_pagerank && s()!.top_pagerank!.length > 0}>
        <ObjectTable title="Most Important Objects (PageRank)" objs={s()!.top_pagerank!} store={store} />
      </Show>

      <TopTablesWidget store={store} />
    </Show>
  );
}
