// Tables.tsx — DB table browser (PBSELECT / DataWindow source).

import { Show, For, createMemo } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";
import type { TableDetail } from "@pb/platform";
import { ComboboxInput } from "@pb/platform";
import { InlineDiagram } from "../../components/diagram/InlineDiagram.js";

// ── Left panel: table list ────────────────────────────────────────────────────

export function TableList(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const tables = () => snap().explore.tables;

  const tableNames = createMemo(() => tables().items.map((t: { table_name: string }) => t.table_name));

  const visible = createMemo(() => {
    const q = tables().filter.toLowerCase();
    if (!q) return tables().items;
    return tables().items.filter((t: { table_name: string }) => t.table_name.toLowerCase().includes(q));
  });

  return (
    <>
      <ComboboxInput
        value={tables().filter}
        onChange={(v) => store.dispatch({ tag: "explore", action: { tag: "tables-filter", q: v } })}
        options={tableNames()}
        placeholder="Filter tables…"
      />
      <Show when={tables().loading}>
        <div class="loading-overlay"><div class="spinner" /> Loading tables…</div>
      </Show>
      <Show when={!tables().loading}>
        <Show
          when={visible().length > 0}
          fallback={<div class="tree-empty">No tables found.</div>}
        >
          <div class="table-list">
            <For each={visible()}>
              {(t) => {
                const isSelected = () => tables().selected === t.table_name;
                return (
                  <div
                    class={`table-list-row${isSelected() ? " selected" : ""}`}
                    onClick={() => store.dispatch({ tag: "explore", action: { tag: "tables-select", tableName: t.table_name } })}
                  >
                    <span class="table-list-name">{t.table_name}</span>
                    <span class="table-list-meta">{t.dw_count} DW · {t.file_count} file{t.file_count !== 1 ? "s" : ""}</span>
                  </div>
                );
              }}
            </For>
          </div>
        </Show>
      </Show>
    </>
  );
}

// ── Right panel: table detail ─────────────────────────────────────────────────

function WhereRow(props: { row: { object: string; idx: number; exp1: string; op: string; exp2: string; logic: string } }) {
  const r = props.row;
  return (
    <tr>
      <td class="dw-sql-cell mono">{r.exp1}</td>
      <td class="dw-sql-cell mono">{r.op}</td>
      <td class="dw-sql-cell mono">{r.exp2}</td>
      <td class="dw-sql-cell">{r.logic || ""}</td>
      <td class="dw-sql-cell dim">{r.object}</td>
    </tr>
  );
}

export function TableDetailPanel(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const tables = () => snap().explore.tables;
  const selected = () => tables().selected;
  const detail = () => tables().detail;

  return (
    <Show when={selected()} fallback={
      <div class="explore-empty">Select a table to see its lineage.</div>
    }>
      {(name) => (
        <Show when={!tables().detailLoading} fallback={
          <div class="loading-overlay"><div class="spinner" /> Loading…</div>
        }>
          <Show when={detail() && !("error" in (detail()!))} fallback={
            <div class="explore-empty">
              {"error" in (detail() ?? {}) ? (detail() as { error: string }).error : ""}
            </div>
          }>
            {(() => {
              const d = detail() as TableDetail;
              return (
                <>
                    <div class="explore-right-header">
                    <span class="badge badge-dw">table</span>
                    <span class="proc-name">{name()}</span>
                    <span class="proc-params">{d.dw_count} DataWindow{d.dw_count !== 1 ? "s" : ""}</span>
                  </div>
                  <div class="explore-right-body" style={{ overflow: "auto" }}>

                    <div class="dw-section-header">DataWindows</div>
                    <div class="table-detail-dw-list">
                      <For each={d.datawindows}>
                        {(dw) => (
                          <div
                            class="table-detail-dw-row clickable"
                            onClick={() => store.dispatch({
                              tag: "explore",
                              action: { tag: "dw-select", dwName: dw.object, nodeId: `dw:${dw.object}` },
                            })}
                          >
                            <span class="badge badge-dw">dw</span>
                            <span class="table-detail-dw-name">{dw.object}</span>
                          </div>
                        )}
                      </For>
                    </div>

                    <div class="dw-section-header">DW–Table Diagram</div>
                    <InlineDiagram kind="dw-tables" params={{ table: name() }} store={props.store} compact />

                    <Show when={d.columns.length > 0}>
                      <div class="dw-section-header">Columns selected</div>
                      <table class="dw-attrs-table">
                        <thead>
                          <tr>
                            <th>Column</th>
                            <th>DataWindow</th>
                          </tr>
                        </thead>
                        <tbody>
                          <For each={d.columns}>
                            {(col) => (
                              <tr>
                                <td class="dw-sql-cell mono">{col.column_fqn}</td>
                                <td class="dw-sql-cell dim">{col.object}</td>
                              </tr>
                            )}
                          </For>
                        </tbody>
                      </table>
                    </Show>

                    <Show when={d.where.length > 0}>
                      <div class="dw-section-header">Where conditions</div>
                      <table class="dw-attrs-table">
                        <thead>
                          <tr>
                            <th>Exp1</th>
                            <th>Op</th>
                            <th>Exp2</th>
                            <th>Logic</th>
                            <th>DataWindow</th>
                          </tr>
                        </thead>
                        <tbody>
                          <For each={d.where}>
                            {(row) => <WhereRow row={row} />}
                          </For>
                        </tbody>
                      </table>
                    </Show>

                  </div>
                </>
              );
            })()}
          </Show>
        </Show>
      )}
    </Show>
  );
}
