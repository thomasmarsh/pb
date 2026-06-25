// ObjectDetail.tsx — Source-first object detail with composable analysis panels.

import { Show, createSignal, createResource, For } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import { ArrowRight, type ObjectDetailResponse, type ProcedureDetailResponse, type TaintPathsResponse, type TaintPathSummary } from "@pb/platform";
import type { ObjectsState } from "@pb/platform";
import { Loading } from "../../components/ui/Loading.js";
import { DetailHeader } from "../../components/detail/DetailHeader.js";
import { BackButton } from "../../components/ui/BackButton.js";
import { EntityListCard } from "../../components/detail/EntityListCard.js";
import { MetricsGrid } from "./detail/MetricsGrid.js";
import { ProceduresCard } from "./detail/ProceduresCard.js";
import { SourceCard } from "./detail/SourceCard.js";
import { AnalysisSummaryBar } from "../../components/detail/AnalysisSummaryBar.js";
import { ContextualPanel } from "../../components/detail/ContextualPanel.js";
import { CFGCore } from "../analysis/CFGCore.js";
import type { ContextActions } from "../../components/source/index.js";
import { RuntimeView } from "../../components/runtime/RuntimeView.js";

const SEVERITY_ORDER: Record<string, number> = { critical: 0, high: 1, medium: 2, low: 3 };

// ── Object-level taint panel ─────────────────────────────────────────────────

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

// ── Proc-scoped panels (opened from SourceContextMenu right-click) ────────────

function ProcCallersPanel(props: {
  procName: string;
  procObject: string;
  store: Store<AppState, AppAction>;
}): import("solid-js").JSX.Element {
  const key = () => `${props.procObject}::${props.procName}`;
  const [data] = createResource(key, async (): Promise<ProcedureDetailResponse> => {
    const res = await fetch(
      `/api/procedures/${encodeURIComponent(props.procObject)}/${encodeURIComponent(props.procName)}`,
    );
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json() as Promise<ProcedureDetailResponse>;
  });
  return (
    <>
      <Show when={data.loading}><Loading /></Show>
      <Show when={data.error}>
        <div class="error-banner">Failed to load callers: {String(data.error)}</div>
      </Show>
      <Show when={!data.loading && !data.error && data()}>
        <EntityListCard
          title=""
          items={(data()?.callers ?? []).map((c) => ({
            type: "procedure" as const,
            name: c.proc,
            context: c.object,
            tooltip: `${c.object}.${c.proc}`,
            onClick: () => props.store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: c.object, procName: c.proc } }),
          }))}
          emptyText="No callers found."
        />
      </Show>
    </>
  );
}

function ProcCalleesPanel(props: {
  procName: string;
  procObject: string;
  store: Store<AppState, AppAction>;
}): import("solid-js").JSX.Element {
  const key = () => `${props.procObject}::${props.procName}`;
  const [data] = createResource(key, async (): Promise<ProcedureDetailResponse> => {
    const res = await fetch(
      `/api/procedures/${encodeURIComponent(props.procObject)}/${encodeURIComponent(props.procName)}`,
    );
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json() as Promise<ProcedureDetailResponse>;
  });
  return (
    <>
      <Show when={data.loading}><Loading /></Show>
      <Show when={data.error}>
        <div class="error-banner">Failed to load callees: {String(data.error)}</div>
      </Show>
      <Show when={!data.loading && !data.error && data()}>
        <EntityListCard
          title=""
          items={(data()?.callees ?? []).map((callee) => {
            const dot = callee.indexOf(".");
            const obj = dot > 0 ? callee.slice(0, dot) : props.procObject;
            const proc = dot > 0 ? callee.slice(dot + 1) : callee;
            return {
              type: "procedure" as const,
              name: proc,
              context: obj,
              onClick: () => props.store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: obj, procName: proc } }),
            };
          })}
          emptyText="No callees found."
        />
      </Show>
    </>
  );
}

function ProcTaintPanel(props: {
  procName: string;
  procObject: string;
  store: Store<AppState, AppAction>;
}): import("solid-js").JSX.Element {
  const key = () => `${props.procObject}::${props.procName}`;
  const [data] = createResource(key, async (): Promise<TaintPathsResponse> => {
    const params = new URLSearchParams({
      object_name: props.procObject,
      proc_name: props.procName,
      limit: "10",
    });
    const res = await fetch("/api/analysis/taint-paths?" + params.toString());
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json() as Promise<TaintPathsResponse>;
  });

  const sorted = (): TaintPathSummary[] =>
    [...(data()?.paths ?? [])].sort(
      (a, b) => (SEVERITY_ORDER[a.severity] ?? 9) - (SEVERITY_ORDER[b.severity] ?? 9),
    );

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
              No taint paths found through this procedure.
            </div>
          }
        >
          <table class="data-table" style={{ "font-size": "12px" }}>
            <thead>
              <tr><th>Severity</th><th>Category</th><th>Source</th><th>Sink</th><th></th></tr>
            </thead>
            <tbody>
              <For each={sorted()}>
                {(path) => (
                  <tr
                    class="clickable"
                    onClick={() => props.store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "taintPathView", pathId: path.id } } })}
                  >
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
        </Show>
      </Show>
    </>
  );
}

// ── Main content ─────────────────────────────────────────────────────────────

function ObjectDetailContent(props: {
  o: ObjectDetailResponse;
  obj: () => ObjectsState["detail"];
  store: Store<AppState, AppAction>;
}) {
  const o = props.o;
  const store = props.store;
  const snap = store.getState();
  const src = () => snap().objects.sourceDetail;
  const selectedProcName = () => snap().objects.selectedProcName ?? undefined;

  const badgeClass = o.kind === "powerscript" ? "badge-ps" : o.kind === "datawindow" ? "badge-dw" : "badge-proj";

  // Object-level panel signals
  const [showCallers, setShowCallers] = createSignal(false);
  const [showDWs, setShowDWs] = createSignal(false);
  const [showTables, setShowTables] = createSignal(false);
  const [showMetrics, setShowMetrics] = createSignal(false);
  const [showTaint, setShowTaint] = createSignal(false);
  const [showPreview, setShowPreview] = createSignal(false);

  // Proc-scoped panel signals (opened from SourceContextMenu right-click)
  type ProcTarget = { procName: string; procObject: string };
  const [procCallersTarget, setProcCallersTarget] = createSignal<ProcTarget | null>(null);
  const [procCalleesTarget, setProcCalleesTarget] = createSignal<ProcTarget | null>(null);
  const [procCfgTarget, setProcCfgTarget] = createSignal<ProcTarget | null>(null);
  const [procTaintTarget, setProcTaintTarget] = createSignal<ProcTarget | null>(null);

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
    ...(o.kind === "powerscript" ? [{
      label: "Preview",
      active: showPreview(),
      onClick: () => setShowPreview((v) => !v),
    }] : []),
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
    setShowPreview(false);
    setProcCallersTarget(null);
    setProcCalleesTarget(null);
    setProcCfgTarget(null);
    setProcTaintTarget(null);
  }

  const contextActions: ContextActions = {
    onFindCallers: (procName, procObject) =>
      setProcCallersTarget((v) => v?.procName === procName && v.procObject === procObject ? null : { procName, procObject }),
    onFindCallees: (procName, procObject) =>
      setProcCalleesTarget((v) => v?.procName === procName && v.procObject === procObject ? null : { procName, procObject }),
    onViewCfg: (procName, procObject) =>
      setProcCfgTarget((v) => v?.procName === procName && v.procObject === procObject ? null : { procName, procObject }),
    onViewTaint: (procName, procObject) =>
      setProcTaintTarget((v) => v?.procName === procName && v.procObject === procObject ? null : { procName, procObject }),
  };

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
          <SourceCard store={store} file={o.file} objectName={o.name} sourceDetail={src()} selectedProcName={selectedProcName()} contextActions={contextActions} />
        </Show>
        <Show when={(o.procedures?.length ?? 0) > 0}>
          <ProceduresCard store={store} objectName={o.name} procedures={o.procedures!} />
        </Show>

        {/* Object-level panels */}
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

        <Show when={showPreview()}>
          <ContextualPanel title={`Preview: ${o.name}`} onClose={() => setShowPreview(false)}>
            <RuntimeView objectName={o.name} windowId={`preview-${o.name}`} store={store} />
          </ContextualPanel>
        </Show>

        {/* Proc-scoped panels (opened from SourceContextMenu) */}
        <Show when={procCallersTarget()}>
          {(t) => (
            <ContextualPanel title={`Callers of ${t().procName}`} onClose={() => setProcCallersTarget(null)}>
              <ProcCallersPanel procName={t().procName} procObject={t().procObject} store={store} />
            </ContextualPanel>
          )}
        </Show>

        <Show when={procCalleesTarget()}>
          {(t) => (
            <ContextualPanel title={`Callees of ${t().procName}`} onClose={() => setProcCalleesTarget(null)}>
              <ProcCalleesPanel procName={t().procName} procObject={t().procObject} store={store} />
            </ContextualPanel>
          )}
        </Show>

        <Show when={procCfgTarget()}>
          {(t) => (
            <ContextualPanel title={`CFG: ${t().procName}`} onClose={() => setProcCfgTarget(null)}>
              <div style={{ height: "420px", display: "flex", "flex-direction": "column" }}>
                <CFGCore
                  object={t().procObject}
                  proc={t().procName}
                  store={store}
                  onGoto={() =>
                    store.dispatch({
                      tag: "nav",
                      action: { tag: "navigate", route: { view: "cfgDiagram", object: t().procObject, proc: t().procName } },
                    })
                  }
                  gotoLabel="Full CFG"
                />
              </div>
            </ContextualPanel>
          )}
        </Show>

        <Show when={procTaintTarget()}>
          {(t) => (
            <ContextualPanel title={`Taint: ${t().procName}`} onClose={() => setProcTaintTarget(null)}>
              <ProcTaintPanel procName={t().procName} procObject={t().procObject} store={store} />
            </ContextualPanel>
          )}
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
