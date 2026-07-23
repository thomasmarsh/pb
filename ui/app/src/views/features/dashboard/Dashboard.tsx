// Dashboard.tsx — Dashboard view.

import { Show, For, createMemo, onMount } from "solid-js";
import { AlertTriangle, ArrowRight, procBadge, type ProcedureRow, type Route } from "@pb/platform";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";
import { TableChip } from "../../components/detail/TableChip.js";
import { Loading } from "@pb/platform";
import { InlineDiagram } from "../../components/diagram/InlineDiagram.js";

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
  const snap = props.store.getState();
  const topTables = () => snap().dashboard.topTables;
  const top = () => topTables().slice(0, 10);

  onMount(() => {
    props.store.dispatch({ tag: "dashboard", action: { tag: "loadTopTables" } });
  });

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

function CodeQualityReportWidget(props: { store: Store<AppState, AppAction> }) {
  const snap = props.store.getState();
  const report = () => snap().dashboard.report;

  onMount(() => {
    props.store.dispatch({ tag: "dashboard", action: { tag: "loadReport" } });
  });

  return (
    <Show when={report()}>
      <div class="card">
        <div class="card-header"><h2>Dead Procedures by Object</h2></div>
        <table class="data-table">
          <thead><tr><th>Object</th><th>Dead Procedures</th></tr></thead>
          <tbody>
            <For each={report()!.dead_procedures_by_object}>
              {(d) => (
                <tr class="clickable"
                    onClick={() => props.store.dispatch({ tag: "objects", action: { tag: "select", name: d.object } })}>
                  <td class="name-cell">{d.object}</td>
                  <td>{String(d.dead_count)}</td>
                </tr>
              )}
            </For>
          </tbody>
        </table>
      </div>

      <div class="card">
        <div class="card-header"><h2>Taint Severity Distribution</h2></div>
        <table class="data-table">
          <thead><tr><th>Severity</th><th>Count</th></tr></thead>
          <tbody>
            <For each={report()!.taint_severity_distribution}>
              {(d) => (
                <tr>
                  <td class="name-cell">{d.severity}</td>
                  <td>{String(d.count)}</td>
                </tr>
              )}
            </For>
          </tbody>
        </table>
      </div>

      <div class="card">
        <div class="card-header"><h2>SQL Statement Complexity</h2></div>
        <table class="data-table">
          <thead><tr><th>Tables Joined</th><th>Statements</th></tr></thead>
          <tbody>
            <For each={report()!.sql_statement_complexity_histogram}>
              {(d) => (
                <tr>
                  <td>{String(d.table_count)}</td>
                  <td>{String(d.statement_count)}</td>
                </tr>
              )}
            </For>
          </tbody>
        </table>
      </div>
    </Show>
  );
}

interface CapabilityRowProps {
  label: string;
  metric: string;
  route:  Route | null;
  store:  Store<AppState, AppAction>;
}

function CapabilityRow(props: CapabilityRowProps) {
  const navigate = () => {
    if (props.route) {
      props.store.dispatch({ tag: "nav", action: { tag: "navigate", route: props.route } });
    }
  };

  return (
    <div class="phase-health-row">
      <span class="phase-health-label">{props.label}</span>
      <span class="phase-health-metric">{props.metric}</span>
      {props.route
        ? <button class="phase-health-link" onClick={navigate}>View <ArrowRight size={13} style={{ "vertical-align": "middle" }} /></button>
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
    { label: "Objects",           value: fmt(s()?.objects),    route: { view: "objects" }       as Route },
    { label: "DataWindows",       value: fmt(dwCount()),        route: { view: "datawindows" }   as Route },
    { label: "DB Tables",         value: fmt(s()?.tables),     route: { view: "tables" }        as Route },
    { label: "Procedures",        value: fmt(s()?.procedures), route: { view: "proceduresList" } as Route },
    { label: "Unreferenced DWs",  value: fmt(s()?.dead_dw),   route: { view: "queries", queryName: "dead-dw" } as Route },
    { label: "Diagnostics",       value: fmt(s()?.parse_error_count ?? 0), route: { view: "errors" } as Route },
    ...(s()?.ddl_loaded ? [
      { label: "Unenforced FKs", value: fmt(s()?.unenforced_fk_count), route: { view: "diagrams", kind: "fk-graph" } as Route },
      { label: "Dead Columns",   value: fmt(s()?.dead_column_count),   route: { view: "tables" }   as Route },
    ] : []),
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
          <span><AlertTriangle size={13} style={{ "vertical-align": "middle" }} /> {fmt(s()!.parse_error_count)} file{(s()!.parse_error_count ?? 1) === 1 ? "" : "s"} failed to parse</span>
          <button class="parse-error-banner-link"
                  onClick={() => store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "errors" } } })}>
            Diagnostics <ArrowRight size={13} style={{ "vertical-align": "middle" }} />
          </button>
        </div>
      </Show>

      {/* DDL-not-loaded banner */}
      <Show when={s()?.ddl_loaded === false}>
        <div class="parse-error-banner">
          <span><AlertTriangle size={13} style={{ "vertical-align": "middle" }} /> No DDL schema loaded — FK and column-usage findings are incomplete. Re-index with <code>--ddl</code>.</span>
        </div>
      </Show>

      {/* Analysis capability rows */}
      <div class="card" style={{ "margin-bottom": "16px" }}>
        <div class="card-header"><h2>Analysis</h2></div>
        <div class="phase-health-rows">
          <CapabilityRow
            label="Structural"
            metric={p1Metric()}
            route={{ view: "deadCode" }}
            store={store}
          />
          <CapabilityRow
            label="Type Resolution"
            metric={(s()?.resolved_type_count ?? 0) > 0
              ? `${fmt(s()!.resolved_type_count)} typed vars · ${fmt(s()!.resolved_call_count)} resolved calls`
              : "—"}
            route={null}
            store={store}
          />
          <CapabilityRow
            label="Taint"
            metric={(s()?.taint_path_count ?? 0) > 0
              ? `${fmt(s()!.taint_path_count)} taint path${s()!.taint_path_count === 1 ? "" : "s"}`
              : "—"}
            route={{ view: "taintExplorer" }}
            store={store}
          />
          <CapabilityRow
            label="Schema Integrity"
            metric={s()?.ddl_loaded
              ? `${fmt(s()!.corroborated_fk_count)} corroborated FKs · ${fmt(s()!.unenforced_fk_count)} unenforced · ${fmt(s()!.co_update_violation_count)} co-update violation${s()!.co_update_violation_count === 1 ? "" : "s"}`
              : "—"}
            route={s()?.ddl_loaded ? { view: "diagrams", kind: "fk-graph" } : null}
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

      <div class="card">
        <div class="card-header">
          <h2>Foreign Key Graph</h2>
        </div>
        <InlineDiagram kind="fk-graph" store={store} compact />
      </div>

      <div class="card">
        <div class="card-header">
          <h2>Window–Table Lattice</h2>
        </div>
        <InlineDiagram kind="window-table-lattice" store={store} compact />
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
      <CodeQualityReportWidget store={store} />
    </Show>
  );
}
