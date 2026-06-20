// ObjectDetail.tsx — Source-first object detail with composable analysis panels.

import { Show, createSignal, createResource, For } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import type { ObjectDetailResponse, TaintPathsResponse, TaintPathSummary } from "../../types/api.js";
import type { ObjectsState } from "./types.js";
import { Loading } from "../../components/ui/Loading.js";
import { DetailHeader } from "../../components/detail/DetailHeader.js";
import { BackButton } from "../../components/ui/BackButton.js";
import { EntityListCard } from "../../components/detail/EntityListCard.js";
import { MetricsGrid } from "./detail/MetricsGrid.js";
import { ProceduresCard } from "./detail/ProceduresCard.js";
import { SourceCard } from "./detail/SourceCard.js";
import { AnalysisSummaryBar } from "../../components/detail/AnalysisSummaryBar.js";
import { ContextualPanel } from "../../components/detail/ContextualPanel.js";
import { ArrowRight } from "../../utils/icons.js";

const SEVERITY_ORDER: Record<string, number> = { critical: 0, high: 1, medium: 2, low: 3 };

function ObjectTaintPanel(props: {
  objectName: string;
  store: Store<AppState, AppAction>;
}): import("solid-js").JSX.Element {
  const [data] = createResource(
    () => props.objectName,
    async (name): Promise<TaintPathsResponse> => {
      const params = new URLSearchParams({ object_name: name, limit: "10" });
      const res = await fetch("/api/analysis/taint-paths?" + params.toString());
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return res.json() as Promise<TaintPathsResponse>;
    },
  );

  const sorted = (): TaintPathSummary[] =>
    [...(data()?.paths ?? [])].sort(
      (a, b) => (SEVERITY_ORDER[a.severity] ?? 9) - (SEVERITY_ORDER[b.severity] ?? 9),
    );

  function openPath(id: number): void {
    props.store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "taintPathView", pathId: id } } });
  }

  return (
    <>
      <Show when={data.loading}><Loading /></Show>
      <Show when={data.error}>
        <div class="error-banner">Failed to load taint paths: {String(data.error)}</div>
      </Show>
      <Show when={!data.loading && !data.error && data()}>
        <Show
          when={sorted().length > 0}
          fallback={
            <div style={{ padding: "8px 0", color: "var(--text-muted)", "font-size": "13px" }}>
              No taint paths found through this object.
            </div>
          }
        >
          <Show when={(data()?.total ?? 0) > 0}>
            <button
              class="filter-pill active"
              style={{ "font-size": "12px", padding: "3px 10px", "margin-bottom": "8px" }}
              onClick={() => props.store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "taintExplorer" } } })}
            >
              Taint Explorer ↗
            </button>
          </Show>
          <table class="data-table" style={{ "font-size": "12px" }}>
            <thead>
              <tr>
                <th>Severity</th>
                <th>Category</th>
                <th>Source</th>
                <th>Sink</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <For each={sorted()}>
                {(path) => (
                  <tr class="clickable" onClick={() => openPath(path.id)}>
                    <td><span class={`badge badge-severity-${path.severity}`}>{path.severity}</span></td>
                    <td>{path.category}</td>
                    <td style={{ "font-size": "11px" }}>{path.source.object}.{path.source.proc}</td>
                    <td style={{ "font-size": "11px" }}>{path.sink.object}.{path.sink.proc}</td>
                    <td><span class="trace-nav-link">View <ArrowRight size={12} style={{ "vertical-align": "middle" }} /></span></td>
                  </tr>
                )}
              </For>
            </tbody>
          </table>
          <Show when={(data()?.total ?? 0) > 10}>
            <div style={{ "font-size": "12px", color: "var(--text-muted)", "margin-top": "6px" }}>
              Showing 10 of {data()!.total} paths.
            </div>
          </Show>
        </Show>
      </Show>
    </>
  );
}

function ObjectDetailContent(props: {
  o: ObjectDetailResponse;
  obj: () => ObjectsState["detail"];
  store: Store<AppState, AppAction>;
}) {
  const o = props.o;
  const store = props.store;
  const snap = store.getState();
  const src = () => snap().objects.sourceDetail;

  const badgeClass = o.kind === "powerscript" ? "badge-ps" : o.kind === "datawindow" ? "badge-dw" : "badge-proj";

  const [showCallers, setShowCallers] = createSignal(false);
  const [showDWs, setShowDWs] = createSignal(false);
  const [showTables, setShowTables] = createSignal(false);
  const [showMetrics, setShowMetrics] = createSignal(false);
  const [showTaint, setShowTaint] = createSignal(false);

  const callerCount = () => o.callers?.length ?? 0;
  const dwCount = () => o.dws_used?.length ?? 0;
  const tableCount = () => o.tables_accessed?.length ?? 0;
  const hasMetrics = () => o.metrics != null;

  const summaryItems = () => [
    {
      label: "Callers",
      count: callerCount(),
      active: showCallers(),
      onClick: () => setShowCallers((v) => !v),
    },
    ...(dwCount() > 0 ? [{
      label: "DWs",
      count: dwCount(),
      active: showDWs(),
      onClick: () => setShowDWs((v) => !v),
    }] : []),
    ...(tableCount() > 0 ? [{
      label: "Tables",
      count: tableCount(),
      active: showTables(),
      onClick: () => setShowTables((v) => !v),
    }] : []),
    ...(hasMetrics() ? [{
      label: "Metrics",
      active: showMetrics(),
      onClick: () => setShowMetrics((v) => !v),
    }] : []),
    {
      label: "Taint",
      active: showTaint(),
      onClick: () => setShowTaint((v) => !v),
    },
  ];

  const subtitle = () => {
    if ((o.ancestors?.length ?? 0) === 0) return undefined;
    return (
      <div style={{ "font-size": "12px", color: "var(--text-muted)", "margin-top": "2px" }}>
        extends {o.ancestors![0]}
      </div>
    );
  };

  function closeAll(): void {
    setShowCallers(false);
    setShowDWs(false);
    setShowTables(false);
    setShowMetrics(false);
    setShowTaint(false);
  }

  return (
    <div
      onKeyDown={(e: KeyboardEvent) => { if (e.key === "Escape") closeAll(); }}
      tabIndex={-1}
    >
      <DetailHeader
        name={o.name}
        badgeClass={badgeClass}
        badgeLabel={o.kind}
        subtitle={subtitle()}
      />

      <AnalysisSummaryBar items={summaryItems()} />

      <div class="detail-body">
        <Show when={o.file} fallback={<p class="muted-note">No source file available.</p>}>
          <SourceCard store={store} file={o.file} objectName={o.name} sourceDetail={src()} />
        </Show>
        <Show when={(o.procedures?.length ?? 0) > 0}>
          <ProceduresCard store={store} objectName={o.name} procedures={o.procedures!} />
        </Show>

        <Show when={showCallers()}>
          <ContextualPanel title={`Callers (${callerCount()})`} onClose={() => setShowCallers(false)}>
            <EntityListCard
              title=""
              items={(o.callers ?? []).map((caller) => ({
                type: "object" as const,
                name: caller,
                onClick: () => store.dispatch({ tag: "objects", action: { tag: "select", name: caller } }),
              }))}
              emptyText="No callers found."
            />
          </ContextualPanel>
        </Show>

        <Show when={showDWs()}>
          <ContextualPanel title={`DataWindows Used (${dwCount()})`} onClose={() => setShowDWs(false)}>
            <EntityListCard
              title=""
              items={(o.dws_used ?? []).map((dw) => ({
                type: "datawindow" as const,
                name: dw,
                onClick: () => store.dispatch({ tag: "datawindows", action: { tag: "select", name: dw } }),
              }))}
            />
          </ContextualPanel>
        </Show>

        <Show when={showTables()}>
          <ContextualPanel title={`Tables Accessed (${tableCount()})`} onClose={() => setShowTables(false)}>
            <EntityListCard
              title=""
              meta="based on all DataWindows and direct SQL"
              items={(o.tables_accessed ?? []).map((tbl) => ({
                type: "table" as const,
                name: tbl,
                onClick: () => store.dispatch({ tag: "tables", action: { tag: "select", name: tbl } }),
              }))}
            />
          </ContextualPanel>
        </Show>

        <Show when={showMetrics() && o.metrics}>
          <ContextualPanel title="Metrics" onClose={() => setShowMetrics(false)}>
            <MetricsGrid metrics={o.metrics!} />
          </ContextualPanel>
        </Show>

        <Show when={showTaint()}>
          <ContextualPanel title="Taint Paths" onClose={() => setShowTaint(false)}>
            <ObjectTaintPanel objectName={o.name} store={store} />
          </ContextualPanel>
        </Show>
      </div>
    </div>
  );
}

export function ObjectDetail(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const obj = () => snap().objects.detail;

  return (
    <>
      <BackButton label="Objects" onClick={() => store.dispatch({ tag: "objects", action: { tag: "back-to-objects" } })} />
      <Show when={obj()} fallback={<Loading />}>
        {(entry) => {
          if ("error" in entry()) {
            return <div class="card"><p style={{ color: "var(--red)" }}>Error: {(entry() as { error: string }).error}</p></div>;
          }
          return <ObjectDetailContent o={entry() as ObjectDetailResponse} obj={obj} store={store} />;
        }}
      </Show>
    </>
  );
}
