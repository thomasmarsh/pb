// DWDetail.tsx — DataWindow detail view, source-first with contextual analysis panels.

import { Show, For, createSignal } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import type { DwDetailResponse, DwControlRow } from "../../types/api.js";
import type { DataWindowFile } from "../../types/ast.generated.js";
import { CodeBlock } from "../../components/detail/CodeBlock.js";
import { DwPreview } from "../../components/DwPreview.js";
import { Loading } from "../../components/ui/Loading.js";
import { DetailHeader } from "../../components/detail/DetailHeader.js";
import { BackButton } from "../../components/ui/BackButton.js";
import { EntityListCard } from "../../components/detail/EntityListCard.js";
import { AnalysisSummaryBar } from "../../components/detail/AnalysisSummaryBar.js";
import type { SummaryItem } from "../../components/detail/AnalysisSummaryBar.js";
import { ContextualPanel } from "../../components/detail/ContextualPanel.js";

function DWControlsTable(props: { controls: DwControlRow[] }) {
  return (
    <div class="card">
      <div class="card-header"><h3>Controls ({props.controls.length})</h3></div>
      <table class="data-table">
        <thead>
          <tr><th>Name</th><th>Type</th><th>Band</th><th>X</th><th>Y</th><th>W</th><th>H</th><th>Expr</th></tr>
        </thead>
        <tbody>
          <For each={props.controls}>
            {(c) => (
              <tr>
                <td class="name-cell">{c.control_name ?? "–"}</td>
                <td>{c.control_type ?? ""}</td>
                <td><span class="badge badge-on">{c.band ?? ""}</span></td>
                <td>{c.x != null ? String(c.x) : ""}</td>
                <td>{c.y != null ? String(c.y) : ""}</td>
                <td>{c.width != null ? String(c.width) : ""}</td>
                <td>{c.height != null ? String(c.height) : ""}</td>
                <td style={{ "max-width": "200px", overflow: "hidden", "text-overflow": "ellipsis", "white-space": "nowrap", "font-size": "11px" }}>
                  {c.expression ?? ""}
                </td>
              </tr>
            )}
          </For>
        </tbody>
      </table>
    </div>
  );
}

export function DwDetailCore(props: { d: DwDetailResponse; layout: DataWindowFile | null; store: Store<AppState, AppAction> }) {
  const d = props.d;
  const store = props.store;

  const [showTables, setShowTables] = createSignal(false);
  const [showUsedByObjects, setShowUsedByObjects] = createSignal(false);
  const [showUsedByProcs, setShowUsedByProcs] = createSignal(false);
  const [showRetrieve, setShowRetrieve] = createSignal(false);

  const hasWhere = d.retrieve_where.length > 0;
  const hasArgs = d.arguments.length > 0;
  const tableCount = d.retrieve_tables.length;
  const usedByObjCount = d.used_by_objects?.length ?? 0;
  const usedByProcCount = d.used_by_procs?.length ?? 0;

  const summaryItems = (): SummaryItem[] => [
    ...(tableCount > 0 ? [{ label: "Tables", count: tableCount, active: showTables(), onClick: () => setShowTables((v) => !v) } as SummaryItem] : []),
    ...(usedByObjCount > 0 ? [{ label: "Used By Objects", count: usedByObjCount, active: showUsedByObjects(), onClick: () => setShowUsedByObjects((v) => !v) } as SummaryItem] : []),
    ...(usedByProcCount > 0 ? [{ label: "Used By Procs", count: usedByProcCount, active: showUsedByProcs(), onClick: () => setShowUsedByProcs((v) => !v) } as SummaryItem] : []),
    ...(hasWhere || hasArgs ? [{ label: "Retrieve", active: showRetrieve(), onClick: () => setShowRetrieve((v) => !v) } as SummaryItem] : []),
  ];

  function handleKeyDown(e: KeyboardEvent): void {
    if (e.key === "Escape") {
      setShowTables(false);
      setShowUsedByObjects(false);
      setShowUsedByProcs(false);
      setShowRetrieve(false);
    }
  }

  return (
    <div onKeyDown={handleKeyDown}>
      <DetailHeader
        name={d.name}
        badgeClass="badge-dw"
        badgeLabel="datawindow"
      />

      <AnalysisSummaryBar items={summaryItems()} />

      <div class="detail-body">
        <div class="card">
          <div class="card-header"><h3>Preview</h3></div>
          <div style={{ padding: "12px" }}>
            <DwPreview layout={props.layout} />
          </div>
        </div>

        <Show when={d.controls.length > 0}>
          <DWControlsTable controls={d.controls} />
        </Show>

        <Show when={d.source}>
          <div class="card">
            <div class="card-header"><h3>Source</h3></div>
            <CodeBlock code={d.source!} />
          </div>
        </Show>

        <Show when={showTables()}>
          <ContextualPanel title={`Tables Accessed (${tableCount})`} onClose={() => setShowTables(false)}>
            <EntityListCard
              title=""
              items={d.retrieve_tables.map((t) => ({
                type: "table" as const,
                name: t,
                onClick: () => store.dispatch({ tag: "tables", action: { tag: "select", name: t } }),
              }))}
            />
          </ContextualPanel>
        </Show>

        <Show when={showUsedByObjects()}>
          <ContextualPanel title={`Used By — Objects (${usedByObjCount})`} onClose={() => setShowUsedByObjects(false)}>
            <EntityListCard
              title=""
              items={(d.used_by_objects ?? []).map((obj) => ({
                type: "object" as const,
                name: obj,
                onClick: () => store.dispatch({ tag: "objects", action: { tag: "select", name: obj } }),
              }))}
            />
          </ContextualPanel>
        </Show>

        <Show when={showUsedByProcs()}>
          <ContextualPanel title={`Used By — Procedures (${usedByProcCount})`} onClose={() => setShowUsedByProcs(false)}>
            <EntityListCard
              title=""
              items={(d.used_by_procs ?? []).map((ref) => ({
                type: "procedure" as const,
                name: ref.proc,
                context: ref.object,
                tooltip: `${ref.object}.${ref.proc}`,
                onClick: () => store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: ref.object, procName: ref.proc } }),
              }))}
            />
          </ContextualPanel>
        </Show>

        <Show when={showRetrieve()}>
          <ContextualPanel title="Retrieve Definition" onClose={() => setShowRetrieve(false)}>
            <>
              <Show when={hasArgs}>
                <div style={{ "padding": "8px 16px" }}>
                  <div style={{ "font-size": "11px", color: "var(--text-muted)", "margin-bottom": "4px" }}>Arguments</div>
                  <table class="data-table">
                    <thead><tr><th>Name</th><th>Type</th></tr></thead>
                    <tbody>
                      <For each={d.arguments}>
                        {(a) => <tr><td class="name-cell">{a.arg_name}</td><td>{a.arg_type ?? ""}</td></tr>}
                      </For>
                    </tbody>
                  </table>
                </div>
              </Show>
              <Show when={hasWhere}>
                <div style={{ "padding": "8px 16px" }}>
                  <div style={{ "font-size": "11px", color: "var(--text-muted)", "margin-bottom": "4px" }}>WHERE Clauses</div>
                  <table class="data-table">
                    <thead><tr><th>#</th><th>Exp1</th><th>Op</th><th>Exp2</th><th>Logic</th></tr></thead>
                    <tbody>
                      <For each={d.retrieve_where}>
                        {(w) => (
                          <tr>
                            <td>{String(w.idx)}</td>
                            <td>{w.exp1 ?? ""}</td>
                            <td><span class="badge badge-event">{w.op ?? ""}</span></td>
                            <td>{w.exp2 ?? ""}</td>
                            <td><span class="badge badge-func">{w.logic ?? ""}</span></td>
                          </tr>
                        )}
                      </For>
                    </tbody>
                  </table>
                </div>
              </Show>
            </>
          </ContextualPanel>
        </Show>
      </div>
    </div>
  );
}

export function DWDetail(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const dw = () => snap().datawindows.dwDetail;
  const layout = () => snap().datawindows.dwLayout;

  return (
    <>
      <BackButton label="DataWindows" onClick={() => store.dispatch({ tag: "datawindows", action: { tag: "back-to-datawindows" } })} />
      <Show when={dw()} fallback={<Loading />}>
        {(entry) => {
          if ("error" in entry()) {
            return <div class="card"><p style={{ color: "var(--red)" }}>Error: {(entry() as { error: string }).error}</p></div>;
          }
          return <DwDetailCore d={entry() as DwDetailResponse} layout={layout()} store={store} />;
        }}
      </Show>
    </>
  );
}
