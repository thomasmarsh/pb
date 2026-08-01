// ProcedureDetail.tsx — Source-first procedure detail with composable analysis panels.

import { Show, For, createResource, createSignal } from "solid-js";
import { ArrowRight, procBadge, type ProcedureDetailResponse, type TaintPathsResponse, type TaintPathSummary } from "@pb/platform";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";
import {
  CodeBlock, Loading, DetailHeader, BackButton, EntityListCard,
  AnalysisSummaryBar, ContextualPanel,
  renderQuickInfoHeader, PROC_TYPE_LABELS, PROC_BADGE_COLORS,
} from "@pb/platform";
import type { SummaryItem } from "@pb/platform";
import { SqlStatementCard } from "../../components/detail/SqlStatementCard.js";
import { CFGCore } from "../analysis/CFGCore.js";
import { WiringCore } from "../analysis/WiringCore.js";
import { FootprintPanel } from "../analysis/FootprintPanel.js";
import { ExplainCore } from "../analysis/ExplainCore.js";

const SEVERITY_ORDER: Record<string, number> = { critical: 0, high: 1, medium: 2, low: 3 };

function ProcTaintCard(props: {
  objectName: string;
  procName: string;
  store: Store<AppState, AppAction>;
}): import("solid-js").JSX.Element {
  const key = () => `${props.objectName}::${props.procName}`;
  const [data] = createResource(key, async (): Promise<TaintPathsResponse> => {
    const params = new URLSearchParams({
      object_name: props.objectName,
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

  function openPath(id: number): void {
    props.store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "taintPathView", pathId: id } } });
  }

  return (
    <>
      <Show when={(data()?.total ?? 0) > 0}>
        <button
          class="filter-pill active"
          style={{ "font-size": "12px", padding: "3px 10px", "margin-bottom": "8px" }}
          onClick={() => props.store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "taintExplorer" } } })}
        >
          Taint Explorer ↗
        </button>
      </Show>
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

function ProcedureDetailContent(props: {
  p: ProcedureDetailResponse;
  store: Store<AppState, AppAction>;
  objectName: string;
}) {
  const { p, store } = props;
  const bc = procBadge(p.proc_type);

  const [showCallers, setShowCallers] = createSignal(false);
  const [showCallees, setShowCallees] = createSignal(false);
  const [showSql, setShowSql] = createSignal(false);
  const [showTaint, setShowTaint] = createSignal(false);
  const [showExplain, setShowExplain] = createSignal(false);
  const [showCfg, setShowCfg] = createSignal(false);
  const [showFootprint, setShowFootprint] = createSignal(false);
  const [diagramView, setDiagramView] = createSignal<"cfg" | "wiring">("cfg");

  const callerCount = () => p.callers?.length ?? 0;
  const calleeCount = () => p.callees?.length ?? 0;
  const sqlCount = () => p.sql_statements?.length ?? 0;

  const summaryItems = (): SummaryItem[] => [
    { label: "Callers", count: callerCount(), active: showCallers(), onClick: () => setShowCallers((v) => !v) },
    { label: "Callees", count: calleeCount(), active: showCallees(), onClick: () => setShowCallees((v) => !v) },
    ...(sqlCount() > 0 ? [{ label: "SQL", count: sqlCount(), active: showSql(), onClick: () => setShowSql((v) => !v) } as SummaryItem] : []),
    ...(p.cyclomatic != null ? [{ label: `CC: ${p.cyclomatic}` } as SummaryItem] : []),
    { label: "Taint", active: showTaint(), onClick: () => setShowTaint((v) => !v) },
    { label: "Explain", active: showExplain(), onClick: () => setShowExplain((v) => !v) },
    { label: "CFG", active: showCfg(), onClick: () => setShowCfg((v) => !v) },
    { label: "Footprint", active: showFootprint(), onClick: () => setShowFootprint((v) => !v) },
  ];

  function handleKeyDown(e: KeyboardEvent): void {
    if (e.key === "Escape") {
      setShowCallers(false);
      setShowCallees(false);
      setShowSql(false);
      setShowTaint(false);
      setShowExplain(false);
      setShowCfg(false);
      setShowFootprint(false);
    }
  }

  const subtitle = (
    <div
      style={{ "font-size": "12px" }}
      innerHTML={renderQuickInfoHeader({
        shape: "callable",
        kindLabel: PROC_TYPE_LABELS[p.proc_type] ?? p.proc_type,
        kindColor: PROC_BADGE_COLORS[p.proc_type] ?? "var(--accent)",
        name: p.name,
        params: p.params ?? "",
        returnType: p.return_type,
      })}
    />
  );

  return (
    <div onKeyDown={handleKeyDown}>
      <DetailHeader
        name={`${p.object}.`}
        badgeClass={`badge-${bc}`}
        badgeLabel={p.proc_type}
        subtitle={subtitle}
      />

      <AnalysisSummaryBar items={summaryItems()} />

      <div class="detail-body">
        <Show when={p.source_original}>
          <CodeBlock
            code={p.source_original!}
            baseLine={p.start_line ?? 1}
            objectName={props.objectName}
            knownObjects={p.knownObjects}
            resolvedCalls={p.resolvedCalls}
            resolvedVarRefs={p.resolvedVarRefs}
            onLineClick={(line) =>
              store.dispatch({ tag: "objects", action: { tag: "go-slice", object: props.objectName, proc: p.name, line, direction: "backward" } })
            }
          />
          <Show when={p.file}>
            <div style={{ "font-size": "11px", color: "var(--text-muted)", "margin-top": "8px" }}>
              {p.file}:{p.start_line ?? ""}–{p.end_line ?? ""}
            </div>
          </Show>
        </Show>

        <Show when={showCallers()}>
          <ContextualPanel title={`Callers (${callerCount()})`} onClose={() => setShowCallers(false)}>
            <EntityListCard
              title=""
              items={(p.callers ?? []).map((caller) => ({
                type: "procedure" as const,
                name: caller.proc,
                context: caller.object,
                tooltip: `${caller.object}.${caller.proc}`,
                onClick: () => store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: caller.object, procName: caller.proc } }),
              }))}
              emptyText="No callers found."
            />
          </ContextualPanel>
        </Show>

        <Show when={showCallees()}>
          <ContextualPanel title={`Callees (${calleeCount()})`} onClose={() => setShowCallees(false)}>
            <EntityListCard
              title=""
              items={(p.callees ?? []).map((callee) => ({
                type: "procedure" as const,
                name: callee,
                onClick: () => {
                  const dotIdx = callee.indexOf(".");
                  if (dotIdx > 0) {
                    store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: callee.slice(0, dotIdx), procName: callee.slice(dotIdx + 1) } });
                  } else {
                    store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: p.object, procName: callee } });
                  }
                },
              }))}
              emptyText="No callees found."
            />
          </ContextualPanel>
        </Show>

        <Show when={showSql() && sqlCount() > 0}>
          <ContextualPanel title={`SQL Statements (${sqlCount()})`} onClose={() => setShowSql(false)}>
            <div class="sql-tab-body">
              <For each={p.sql_statements!}>
                {(stmt) => <SqlStatementCard stmt={stmt} store={store} />}
              </For>
            </div>
          </ContextualPanel>
        </Show>

        <Show when={showTaint()}>
          <ContextualPanel title="Taint Paths" onClose={() => setShowTaint(false)}>
            <ProcTaintCard objectName={props.objectName} procName={p.name} store={store} />
          </ContextualPanel>
        </Show>

        <Show when={showExplain()}>
          <ContextualPanel title="Explain" onClose={() => setShowExplain(false)}>
            <div style={{ height: "420px", display: "flex", "flex-direction": "column" }}>
              <ExplainCore
                object={p.object}
                proc={p.name}
                store={store}
                onGoto={() =>
                  store.dispatch({
                    tag: "nav",
                    action: { tag: "navigate", route: { view: "explainView", object: p.object, proc: p.name } },
                  })
                }
                gotoLabel="Full Explain"
              />
            </div>
          </ContextualPanel>
        </Show>

        <Show when={showCfg()}>
          <ContextualPanel title={diagramView() === "cfg" ? "Control Flow Graph" : "Wiring Diagram"} onClose={() => setShowCfg(false)}>
            <div class="diagram-view-toggle" style={{ display: "flex", gap: "6px", "margin-bottom": "8px" }}>
              <button
                class={diagramView() === "cfg" ? "filter-pill active" : "filter-pill"}
                onClick={() => setDiagramView("cfg")}
              >
                CFG
              </button>
              <button
                class={diagramView() === "wiring" ? "filter-pill active" : "filter-pill"}
                onClick={() => setDiagramView("wiring")}
              >
                Wiring
              </button>
            </div>
            <div style={{ height: "420px", display: "flex", "flex-direction": "column" }}>
              <Show when={diagramView() === "cfg"}>
                <CFGCore
                  object={p.object}
                  proc={p.name}
                  store={store}
                  onGoto={() =>
                    store.dispatch({
                      tag: "nav",
                      action: { tag: "navigate", route: { view: "cfgDiagram", object: p.object, proc: p.name } },
                    })
                  }
                  gotoLabel="Full CFG"
                />
              </Show>
              <Show when={diagramView() === "wiring"}>
                <WiringCore store={store} object={p.object} proc={p.name} />
              </Show>
            </div>
          </ContextualPanel>
        </Show>

        <Show when={showFootprint()}>
          <ContextualPanel title="Procedure Footprint" onClose={() => setShowFootprint(false)}>
            <FootprintPanel store={store} target={{ kind: "proc", object: p.object, proc: p.name }} />
          </ContextualPanel>
        </Show>
      </div>
    </div>
  );
}

export function ProcedureDetail(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const proc = () => snap().objects.procedureDetail;
  const objectName = () => {
    const r = snap().nav.route;
    return r.view === "procedureDetail" ? r.name : "";
  };

  return (
    <>
      <BackButton
        label={objectName()}
        onClick={() => store.dispatch({ tag: "objects", action: { tag: "select", name: objectName() } })}
      />
      <Show when={proc()} fallback={<Loading />}>
        {(entry) => {
          if ("error" in entry()) {
            return (
              <div class="card">
                <p style={{ color: "var(--red)" }}>Error: {(entry() as { error: string }).error}</p>
              </div>
            );
          }
          const p = entry() as ProcedureDetailResponse;
          return (
            <ProcedureDetailContent
              p={p}
              store={store}
              objectName={objectName()}
            />
          );
        }}
      </Show>
    </>
  );
}
