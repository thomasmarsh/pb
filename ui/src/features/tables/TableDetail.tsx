// features/tables/TableDetail.tsx — Source-first table detail with contextual analysis panels.

import { For, Show, createSignal } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../app/src/state.js";
import type { AppAction } from "../../../app/src/actions.js";
import type { TableDetail as TableDetailData, TableProcedureRef, ImpactInheritedRef, ImpactDirectRef } from "@pb/platform";
import { Loading } from "../../components/ui/Loading.js";
import { ColumnRow } from "../../components/detail/ColumnRow.js";
import { EntityCard } from "../../components/detail/EntityCard.js";
import { DetailHeader } from "../../components/detail/DetailHeader.js";
import { BackButton } from "../../components/ui/BackButton.js";
import { AnalysisSummaryBar } from "../../components/detail/AnalysisSummaryBar.js";
import type { SummaryItem } from "../../components/detail/AnalysisSummaryBar.js";
import { ContextualPanel } from "../../components/detail/ContextualPanel.js";

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
                  onClick={() => props.store.dispatch({ tag: "objects", action: { tag: "select", name: row.object } })}
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

function ImpactPanel(props: { direct: ImpactDirectRef[]; inherited: ImpactInheritedRef[]; store: Store<AppState, AppAction> }) {
  return (
    <>
      <div>
        <div class="card-header" style={{ padding: "8px 16px" }}><h3>Direct Access ({props.direct.length})</h3></div>
        <table class="data-table">
          <thead><tr><th>Object</th><th>Source</th><th>Operation</th></tr></thead>
          <tbody>
            <For each={props.direct} fallback={
              <tr><td colspan="3" style={{ color: "var(--text-muted)", padding: "12px" }}>None.</td></tr>
            }>
              {(row) => (
                <tr>
                  <td class="name-cell" style={{ padding: "4px 8px" }}>
                    <EntityCard
                      type={row.source === "datawindow" ? "datawindow" : "object"}
                      name={row.object}
                      onClick={() => props.store.dispatch(
                        row.source === "datawindow"
                          ? { tag: "datawindows", action: { tag: "select", name: row.object } }
                          : { tag: "objects", action: { tag: "select", name: row.object } },
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
      <Show when={props.inherited.length > 0}>
        <div>
          <div class="card-header" style={{ padding: "8px 16px" }}><h3>Inherited Access ({props.inherited.length})</h3></div>
          <For each={groupByDepth(props.inherited)}>
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
                            onClick={() => props.store.dispatch({ tag: "objects", action: { tag: "select", name: row.descendant } })}
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
    </>
  );
}

function DetailContent(props: { detail: TableDetailData; store: Store<AppState, AppAction> }) {
  const d = props.detail;
  const store = props.store;

  const [showDwReaders, setShowDwReaders] = createSignal(false);
  const [showReaders, setShowReaders] = createSignal(false);
  const [showWriters, setShowWriters] = createSignal(false);
  const [showImpact, setShowImpact] = createSignal(false);

  const readers = d.procedures.filter((p) => !WRITE_OPS.has(p.operation));
  const writers = d.procedures.filter((p) => WRITE_OPS.has(p.operation));
  const impact = d.impact;
  const impactCount = impact.direct.length + impact.inherited.length;
  const hasImpact = impactCount > 0;

  const summaryItems = (): SummaryItem[] => [
    { label: "DW Readers", count: d.datawindows.length, active: showDwReaders(), onClick: () => setShowDwReaders((v) => !v) },
    { label: "Readers", count: readers.length, active: showReaders(), onClick: () => setShowReaders((v) => !v) },
    { label: "Writers", count: writers.length, active: showWriters(), onClick: () => setShowWriters((v) => !v) },
    ...(hasImpact ? [{ label: "Impact", count: impactCount, active: showImpact(), onClick: () => setShowImpact((v) => !v) } as SummaryItem] : []),
  ];

  function handleKeyDown(e: KeyboardEvent): void {
    if (e.key === "Escape") {
      setShowDwReaders(false);
      setShowReaders(false);
      setShowWriters(false);
      setShowImpact(false);
    }
  }

  const subtitle = (
    <p style={{ color: "var(--text-muted)", margin: "0", "font-size": "13px" }}>
      {d.dw_count} DW reader{d.dw_count !== 1 ? "s" : ""} · {readers.length} procedure reader{readers.length !== 1 ? "s" : ""} · {writers.length} writer{writers.length !== 1 ? "s" : ""}
    </p>
  );

  return (
    <div onKeyDown={handleKeyDown}>
      <DetailHeader
        name={d.table_name}
        badgeClass="badge-dw"
        badgeLabel="table"
        subtitle={subtitle}
      />

      <AnalysisSummaryBar items={summaryItems()} />

      <div class="detail-body">
        {/* Columns are always visible — they are the primary content for a table */}
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

        <Show when={showDwReaders()}>
          <ContextualPanel title={`DataWindow Readers (${d.datawindows.length})`} onClose={() => setShowDwReaders(false)}>
            <Show when={d.datawindows.length > 0} fallback={
              <p style={{ color: "var(--text-muted)", padding: "12px 16px" }}>None.</p>
            }>
              <div class="entity-card-list" style={{ padding: "8px 16px" }}>
                <For each={d.datawindows}>
                  {(dw) => (
                    <EntityCard
                      type="datawindow"
                      name={dw.dw_name}
                      onClick={() => store.dispatch({ tag: "datawindows", action: { tag: "select", name: dw.dw_name } })}
                    />
                  )}
                </For>
              </div>
            </Show>
          </ContextualPanel>
        </Show>

        <Show when={showReaders()}>
          <ContextualPanel title={`Procedure Readers — SELECT (${readers.length})`} onClose={() => setShowReaders(false)}>
            <ProcTable rows={readers} store={store} />
          </ContextualPanel>
        </Show>

        <Show when={showWriters()}>
          <ContextualPanel title={`Procedure Writers — INSERT / UPDATE / DELETE (${writers.length})`} onClose={() => setShowWriters(false)}>
            <ProcTable rows={writers} store={store} />
          </ContextualPanel>
        </Show>

        <Show when={showImpact()}>
          <ContextualPanel title={`Impact (${impactCount})`} onClose={() => setShowImpact(false)}>
            <ImpactPanel direct={impact.direct} inherited={impact.inherited} store={store} />
          </ContextualPanel>
        </Show>
      </div>
    </div>
  );
}

export function TableDetail(props: { store: Store<AppState, AppAction> }) {
  const snap = props.store.getState();
  const ts = () => snap().tables;

  return (
    <>
      <BackButton label="Tables" onClick={() => props.store.dispatch({ tag: "tables", action: { tag: "back" } })} />
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
