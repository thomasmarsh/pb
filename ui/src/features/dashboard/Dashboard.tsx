// Dashboard.tsx — Dashboard view.

import { Show, For, createMemo, onMount } from "solid-js";
import { useSnapshot } from "../../core/store.js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import type { ProcedureRow } from "../../types/api.js";
import { procBadge } from "../../utils/format.js";

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
                  onClick={() => props.store.dispatch({ tag: "objects", action: { type: "proc-select", objectName: p.object, procName: p.name } })}>
                <td class="name-cell">{p.object}</td>
                <td>{p.name}</td>
                <td><span class={`badge ${procBadge(p.proc_type)}`}>{p.proc_type}</span></td>
                <td>{p.cyclomatic != null ? <span class="badge badge-cc">{String(p.cyclomatic)}</span> : "\u2013"}</td>
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
                  onClick={() => props.store.dispatch({ tag: "objects", action: { type: "select", name: p.object } })}>
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

import { Loading } from "../../components/Loading.js";

export function Dashboard(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = useSnapshot(store.state);

  onMount(() => {
    store.dispatch({ tag: "nav", action: { type: "navigate", route: { view: "dashboard" } } });
    if (!snap().dashboard.stats) store.dispatch({ tag: "dashboard", action: { type: "load" } });
  });

  const s = () => snap().dashboard.stats;

  const metrics = createMemo(() => {
    const stats = s();
    if (!stats) return [];
    return [
      ["Objects", stats.objects],
      ["Procedures", stats.procedures],
      ["DataWindows", stats.by_kind?.find(k => k.kind === "datawindow")?.count],
      ["Inheritance edges", stats.inherits],
      ["Call edges", stats.calls],
      ["DW Controls", stats.dw_controls],
    ] as [string, number | undefined][];
  });

  return (
    <Show when={s()} fallback={<Loading />}>
      <div class="metric-grid">
        <For each={metrics()}>
          {([label, val]) => (
            <div class="metric-card">
              <div class="label">{label}</div>
              <div class="value">{String(val ?? "\u2013")}</div>
            </div>
          )}
        </For>
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
    </Show>
  );
}
