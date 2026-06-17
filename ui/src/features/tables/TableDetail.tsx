// features/tables/TableDetail.tsx — Detail view with Readers / Writers tabs.

import { For, Show, createSignal } from "solid-js";
import { useSnapshot } from "../../core/store.js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import type { TableDetail as TableDetailData, TableProcedureRef, ImpactInheritedRef } from "../../types/api.js";
import { Loading } from "../../components/Loading.js";
import { ColumnRow } from "../../components/ColumnRow.js";
import { InlineDiagram } from "../../components/InlineDiagram.js";

type Tab = "readers" | "writers" | "columns" | "impact" | "diagram";

const WRITE_OPS = new Set(["INSERT", "UPDATE", "DELETE"]);

const OP_BADGE: Record<string, string> = {
  INSERT: "badge-func",   // green-ish
  UPDATE: "badge-event",  // amber-ish
  DELETE: "badge-dw",     // red-ish (closest available badge colour)
};

function ProcTable(props: { rows: TableProcedureRef[]; store: Store<AppState, AppAction> }) {
  return (
    <table class="data-table">
      <thead><tr><th>Object</th><th>Procedure</th><th>Operation</th></tr></thead>
      <tbody>
        <For each={props.rows} fallback={
          <tr><td colspan="3" style={{ color: "var(--text-muted)", padding: "12px" }}>None.</td></tr>
        }>
          {(row) => (
            <tr>
              <td class="name-cell clickable"
                  onClick={() => props.store.dispatch({ tag: "objects", action: { type: "select", name: row.object } })}>
                {row.object}
              </td>
              <td>{row.proc_name ?? "–"}</td>
              <td><span class={`badge ${OP_BADGE[row.operation] ?? "badge-on"}`}>{row.operation}</span></td>
            </tr>
          )}
        </For>
      </tbody>
    </table>
  );
}

function groupByDepth(rows: ImpactInheritedRef[]): [number, ImpactInheritedRef[]][] {
  const byDepth = new Map<number, ImpactInheritedRef[]>();
  for (const row of rows) {
    const bucket = byDepth.get(row.depth);
    if (bucket) bucket.push(row);
    else byDepth.set(row.depth, [row]);
  }
  return [...byDepth.entries()].sort((a, b) => a[0] - b[0]);
}

function ImpactTab(props: { detail: TableDetailData; store: Store<AppState, AppAction> }) {
  const impact = props.detail.impact;
  const isEmpty = impact.direct.length === 0 && impact.inherited.length === 0;

  return (
    <>
      <Show when={!isEmpty} fallback={
        <div class="card" style={{ padding: "32px", "text-align": "center", color: "var(--text-muted)" }}>
          No inheritance relationships found for this table.
        </div>
      }>
        <div class="card">
          <div class="card-header"><h3>Direct access ({impact.direct.length})</h3></div>
          <table class="data-table">
            <thead><tr><th>Object</th><th>Source</th><th>Operation</th></tr></thead>
            <tbody>
              <For each={impact.direct} fallback={
                <tr><td colspan="3" style={{ color: "var(--text-muted)", padding: "12px" }}>None.</td></tr>
              }>
                {(row) => (
                  <tr>
                    <td class="name-cell clickable"
                        onClick={() => props.store.dispatch(
                          row.source === "datawindow"
                            ? { tag: "datawindows", action: { type: "select", name: row.object } }
                            : { tag: "objects", action: { type: "select", name: row.object } },
                        )}>
                      {row.object}
                    </td>
                    <td><span class={`badge ${row.source === "datawindow" ? "badge-dw" : "badge-on"}`}>{row.source}</span></td>
                    <td>{row.operation}</td>
                  </tr>
                )}
              </For>
            </tbody>
          </table>
        </div>

        <div class="card">
          <div class="card-header"><h3>Inherited access ({impact.inherited.length})</h3></div>
          <Show when={impact.inherited.length > 0} fallback={
            <p style={{ color: "var(--text-muted)", padding: "12px 16px" }}>No descendants inherit access to this table.</p>
          }>
            <For each={groupByDepth(impact.inherited)}>
              {([depth, rows]) => (
                <table class="data-table">
                  <thead><tr><th colspan="2">depth {depth}</th></tr></thead>
                  <tbody>
                    <For each={rows}>
                      {(row) => (
                        <tr>
                          <td class="name-cell clickable"
                              onClick={() => props.store.dispatch({ tag: "objects", action: { type: "select", name: row.descendant } })}>
                            {row.descendant}
                          </td>
                          <td style={{ color: "var(--text-muted)" }}>inherits from {row.ancestor}</td>
                        </tr>
                      )}
                    </For>
                  </tbody>
                </table>
              )}
            </For>
          </Show>
        </div>
      </Show>
    </>
  );
}

function DetailContent(props: { detail: TableDetailData; store: Store<AppState, AppAction> }) {
  const [tab, setTab] = createSignal<Tab>("readers");
  const d = props.detail;
  const readers = d.procedures.filter((p) => !WRITE_OPS.has(p.operation));
  const writers = d.procedures.filter((p) => WRITE_OPS.has(p.operation));

  return (
    <>
      <h2 style={{ "margin-bottom": "8px", "font-size": "20px" }}>
        {d.table_name}{" "}
        <span class="badge badge-dw">table</span>
      </h2>
      <p style={{ color: "var(--text-muted)", "margin-bottom": "16px" }}>
        {d.dw_count} DW reader{d.dw_count !== 1 ? "s" : ""} · {readers.length} procedure reader{readers.length !== 1 ? "s" : ""} · {writers.length} writer{writers.length !== 1 ? "s" : ""}
      </p>

      <div class="tab-bar" style={{ display: "flex", gap: "8px", "margin-bottom": "16px" }}>
        {(["readers", "writers", "columns", "impact", "diagram"] as Tab[]).map((t) => (
          <button
            class={tab() === t ? "tab-btn active" : "tab-btn"}
            onClick={() => setTab(t)}
          >
            {t.charAt(0).toUpperCase() + t.slice(1)}
          </button>
        ))}
      </div>

      <Show when={tab() === "readers"}>
        <Show when={d.datawindows.length > 0}>
          <div class="card">
            <div class="card-header"><h3>DataWindows</h3></div>
            <div style={{ display: "flex", "flex-wrap": "wrap", gap: "6px", padding: "12px 16px" }}>
              <For each={d.datawindows}>
                {(dw) => (
                  <span
                    class="badge badge-dw clickable"
                    style={{ cursor: "pointer" }}
                    onClick={() => props.store.dispatch({ tag: "datawindows", action: { type: "select", name: dw.dw_name } })}
                  >
                    {dw.dw_name}
                  </span>
                )}
              </For>
            </div>
          </div>
        </Show>
        <div class="card">
          <div class="card-header"><h3>Procedure readers (SELECT)</h3></div>
          <ProcTable rows={readers} store={props.store} />
        </div>
      </Show>

      <Show when={tab() === "writers"}>
        <div class="card">
          <div class="card-header"><h3>Procedure writers (INSERT / UPDATE / DELETE)</h3></div>
          <ProcTable rows={writers} store={props.store} />
        </div>
      </Show>

      <Show when={tab() === "columns"}>
        <Show when={d.columns_detail.length > 0} fallback={
          <div class="card" style={{ padding: "32px", "text-align": "center", color: "var(--text-muted)" }}>
            No column-level data available for this table.
          </div>
        }>
          <table class="data-table">
            <thead>
              <tr><th>Column</th><th>DW reads</th><th>PS reads</th><th>PS writes</th></tr>
            </thead>
            <tbody>
              <For each={d.columns_detail}>
                {(col) => <ColumnRow col={col} store={props.store} />}
              </For>
            </tbody>
          </table>
        </Show>
      </Show>

      <Show when={tab() === "impact"}>
        <ImpactTab detail={d} store={props.store} />
      </Show>

      <Show when={tab() === "diagram"}>
        <div class="card">
          <div class="card-header"><h3>Procedure → Table Relationships</h3></div>
          <InlineDiagram kind="proc-tables" params={{ table: d.table_name }} store={props.store} />
        </div>
        <div class="card">
          <div class="card-header"><h3>Table Lineage</h3></div>
          <InlineDiagram kind="table-lineage" params={{ table: d.table_name }} store={props.store} />
        </div>
      </Show>
    </>
  );
}

export function TableDetail(props: { store: Store<AppState, AppAction> }) {
  const snap = useSnapshot(props.store.state);
  const ts = () => snap().tables;

  return (
    <>
      <button class="back-btn"
              onClick={() => props.store.dispatch({ tag: "tables", action: { type: "back" } })}>
        {"←"} Back to Tables
      </button>
      <Show when={ts().detail} fallback={
        <Show when={ts().error} fallback={<Loading />}>
          <div class="card">
            <p style={{ color: "var(--red)", padding: "16px" }}>Error: {ts().error}</p>
          </div>
        </Show>
      }>
        {(detail) => <DetailContent detail={detail()} store={props.store} />}
      </Show>
    </>
  );
}
