// features/analysis/TaintPathView.tsx — Single taint path view via LinearTrace.

import { Show, createResource } from "solid-js";
import type { JSX } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import type { TaintPathDetail } from "../../types/api.js";
import { AnalysisView } from "./AnalysisView.js";
import { LinearTrace } from "./LinearTrace.js";
import { Loading } from "../../components/ui/Loading.js";

export function TaintPathView(props: { store: Store<AppState, AppAction> }): JSX.Element {
  const snap = props.store.getState();

  const pathId = (): number => {
    const r = snap().nav.route;
    return r.view === "taintPathView" ? r.pathId : 0;
  };

  const [data] = createResource(pathId, async (id): Promise<TaintPathDetail> => {
    const res = await fetch(`/api/analysis/taint-paths/${id}`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json() as Promise<TaintPathDetail>;
  });

  function navigateToProc(object: string, proc: string, line?: number): void {
    props.store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: object, procName: proc } });
    // line anchor not yet implemented — navigates to procedure detail
    void line;
  }

  function navigateToPrevPath(): void {
    const id = pathId();
    if (id <= 1) return;
    props.store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "taintPathView", pathId: id - 1 } } });
  }

  function navigateToNextPath(): void {
    const id = pathId();
    props.store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "taintPathView", pathId: id + 1 } } });
  }

  const title = () => {
    const d = data();
    if (!d) return `Taint Path ${pathId()}`;
    return `${d.source.object}.${d.source.proc} → ${d.sink.object}.${d.sink.proc}`;
  };

  const contextLabel = () => {
    const d = data();
    if (!d) return "";
    return `${d.category} · ${d.severity} severity`;
  };

  return (
    <AnalysisView
      title={title()}
      contextLabel={contextLabel()}
      assumptions="Taint propagation is context-insensitive: the same procedure is not split by call site. Dynamic dispatch is not resolved. Analysis covers intra-procedural def-use chains and inter-procedural argument/return flow."
    >
      <Show when={data.loading}>
        <Loading />
      </Show>

      <Show when={data.error}>
        <div class="error-banner">
          Failed to load taint path {pathId()}: {String(data.error)}
        </div>
      </Show>

      <Show when={!data.loading && !data.error && data()}>
        {(d) => (
          <>
            <div class="taint-path-meta card">
              <div class="taint-meta-row">
                <span class="section-label">Source</span>
                <span class="taint-meta-val">
                  {d().source.object}.{d().source.proc}
                  <Show when={d().source.line != null}>
                    <span class="trace-step-line"> :{d().source.line}</span>
                  </Show>
                  <span class="badge badge-muted" style={{ "margin-left": "6px" }}>{d().source.type}</span>
                </span>
              </div>
              <div class="taint-meta-row">
                <span class="section-label">Sink</span>
                <span class="taint-meta-val">
                  {d().sink.object}.{d().sink.proc}
                  <Show when={d().sink.line != null}>
                    <span class="trace-step-line"> :{d().sink.line}</span>
                  </Show>
                  <span class="badge badge-muted" style={{ "margin-left": "6px" }}>{d().sink.type}</span>
                </span>
              </div>
              <div class="taint-meta-row">
                <span class="section-label">Severity</span>
                <span class={`badge badge-severity-${d().severity}`}>{d().severity}</span>
              </div>
              <div class="taint-meta-row">
                <span class="section-label">Category</span>
                <span class="taint-meta-val">{d().category}</span>
              </div>
            </div>

            <LinearTrace
              steps={d().steps}
              traceType="taint"
              traversedProcs={extractProcs(d().steps)}
              onPrevPath={navigateToPrevPath}
              onNextPath={navigateToNextPath}
              onNavigateToProc={navigateToProc}
            />
          </>
        )}
      </Show>
    </AnalysisView>
  );
}

function extractProcs(steps: TaintPathDetail["steps"]): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const s of steps) {
    const key = `${s.object}.${s.proc_name}`;
    if (!seen.has(key)) { seen.add(key); result.push(key); }
  }
  return result;
}
