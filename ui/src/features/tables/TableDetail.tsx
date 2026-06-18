// features/tables/TableDetail.tsx — Detail view with FaceToggle Source/Analysis faces.

import { For, Show, createEffect } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import type { TableDetail as TableDetailData, TableProcedureRef, ImpactInheritedRef } from "../../types/api.js";
import { Loading } from "../../components/Loading.js";
import { ColumnRow } from "../../components/ColumnRow.js";
import { FaceToggle } from "../../components/FaceToggle.js";
import { PhaseGateInline } from "../../components/PhaseGate.js";
import { EntityCard } from "../../components/EntityCard.js";

const WRITE_OPS = new Set(["INSERT", "UPDATE", "DELETE"]);

const OP_BADGE: Record<string, string> = {
  INSERT: "badge-func",
  UPDATE: "badge-event",
  DELETE: "badge-dw",
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
              <td class="name-cell" style={{ padding: "4px 8px" }}>
                <EntityCard
                  type="object"
                  name={row.object}
                  onClick={() => props.store.dispatch({ tag: "objects", action: { type: "select", name: row.object } })}
                />
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

function DetailContent(props: { detail: TableDetailData; store: Store<AppState, AppAction> }) {
  const d = props.detail;
  const store = props.store;
  const snap = store.getState();
  const face = () => snap().tables.tableFace;

  let scrollEl: HTMLDivElement | undefined;

  createEffect(() => {
    const pos = snap().tables.tableScrollPos[d.table_name];
    if (!pos || !scrollEl) return;
    scrollEl.scrollTop = face() === "source" ? pos.source : pos.analysis;
  });

  const readers = d.procedures.filter((p) => !WRITE_OPS.has(p.operation));
  const writers = d.procedures.filter((p) => WRITE_OPS.has(p.operation));

  const impact = d.impact;
  const hasImpact = impact.direct.length > 0 || impact.inherited.length > 0;

  return (
    <>
      <div class="detail-header">
        <div>
          <h2 style={{ "margin": "0 0 4px 0", "font-size": "20px" }}>
            {d.table_name}{" "}
            <span class="badge badge-dw">table</span>
          </h2>
          <p style={{ color: "var(--text-muted)", margin: "0", "font-size": "13px" }}>
            {d.dw_count} DW reader{d.dw_count !== 1 ? "s" : ""} · {readers.length} procedure reader{readers.length !== 1 ? "s" : ""} · {writers.length} writer{writers.length !== 1 ? "s" : ""}
          </p>
        </div>
        <FaceToggle
          face={face()}
          phaseLabel="P1"
          onToggle={(newFace, scrollTop) => {
            store.dispatch({ tag: "tables", action: { type: "set-table-face", name: d.table_name, face: newFace, scrollTop } });
          }}
          scrollAreaRef={() => scrollEl}
        />
      </div>

      <div class="detail-body" ref={scrollEl}>
        {/* ── Source face: column listing ───────────────────────────────── */}
        <Show when={face() === "source"}>
          <Show when={d.columns_detail.length > 0} fallback={
            <div class="card" style={{ padding: "32px", "text-align": "center", color: "var(--text-muted)" }}>
              No column-level data available for this table.
            </div>
          }>
            <div class="card">
              <div class="card-header"><h3>Columns ({d.columns_detail.length})</h3></div>
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
            </div>
          </Show>
        </Show>

        {/* ── Analysis face: readers / writers / impact as cards ────────── */}
        <Show when={face() === "analysis"}>
          {/* Readers */}
          <div class="card">
            <div class="card-header"><h3>DataWindow Readers ({d.datawindows.length})</h3></div>
            <Show when={d.datawindows.length > 0} fallback={
              <p style={{ color: "var(--text-muted)", padding: "12px 16px" }}>None.</p>
            }>
              <div class="entity-card-list" style={{ padding: "8px 16px" }}>
                <For each={d.datawindows}>
                  {(dw) => (
                    <EntityCard
                      type="datawindow"
                      name={dw.dw_name}
                      onClick={() => store.dispatch({ tag: "datawindows", action: { type: "select", name: dw.dw_name } })}
                    />
                  )}
                </For>
              </div>
            </Show>
          </div>

          <div class="card">
            <div class="card-header"><h3>Procedure Readers — SELECT ({readers.length})</h3></div>
            <ProcTable rows={readers} store={store} />
          </div>

          {/* Writers */}
          <div class="card">
            <div class="card-header"><h3>Procedure Writers — INSERT / UPDATE / DELETE ({writers.length})</h3></div>
            <ProcTable rows={writers} store={store} />
          </div>

          {/* Impact */}
          <Show when={hasImpact}>
            <div class="card">
              <div class="card-header"><h3>Direct Access ({impact.direct.length})</h3></div>
              <table class="data-table">
                <thead><tr><th>Object</th><th>Source</th><th>Operation</th></tr></thead>
                <tbody>
                  <For each={impact.direct} fallback={
                    <tr><td colspan="3" style={{ color: "var(--text-muted)", padding: "12px" }}>None.</td></tr>
                  }>
                    {(row) => (
                      <tr>
                        <td class="name-cell" style={{ padding: "4px 8px" }}>
                          <EntityCard
                            type={row.source === "datawindow" ? "datawindow" : "object"}
                            name={row.object}
                            onClick={() => store.dispatch(
                              row.source === "datawindow"
                                ? { tag: "datawindows", action: { type: "select", name: row.object } }
                                : { tag: "objects", action: { type: "select", name: row.object } },
                            )}
                          />
                        </td>
                        <td><span class={`badge ${row.source === "datawindow" ? "badge-dw" : "badge-on"}`}>{row.source}</span></td>
                        <td>{row.operation}</td>
                      </tr>
                    )}
                  </For>
                </tbody>
              </table>
            </div>

            <Show when={impact.inherited.length > 0}>
              <div class="card">
                <div class="card-header"><h3>Inherited Access ({impact.inherited.length})</h3></div>
                <For each={groupByDepth(impact.inherited)}>
                  {([depth, rows]) => (
                    <table class="data-table">
                      <thead><tr><th colspan="2">depth {depth}</th></tr></thead>
                      <tbody>
                        <For each={rows}>
                          {(row) => (
                            <tr>
                              <td class="name-cell" style={{ padding: "4px 8px" }}>
                                <EntityCard
                                  type="object"
                                  name={row.descendant}
                                  onClick={() => store.dispatch({ tag: "objects", action: { type: "select", name: row.descendant } })}
                                />
                              </td>
                              <td style={{ color: "var(--text-muted)" }}>inherits from {row.ancestor}</td>
                            </tr>
                          )}
                        </For>
                      </tbody>
                    </table>
                  )}
                </For>
              </div>
            </Show>
          </Show>

          {/* Phase gates */}
          <PhaseGateInline
            phase={3}
            section="Taint Paths"
            label="requires taint analysis"
            description="Taint flow through this table's columns is available after a P3 taint analysis run."
          />
          <PhaseGateInline
            phase={4}
            section="Formal Access Constraints"
            label="requires formal verification"
            description="Formally verified access constraints for this table require P4 formal verification infrastructure."
          />
        </Show>
      </div>
    </>
  );
}

export function TableDetail(props: { store: Store<AppState, AppAction> }) {
  const snap = props.store.getState();
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
