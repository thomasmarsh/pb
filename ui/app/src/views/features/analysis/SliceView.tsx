// features/analysis/SliceView.tsx — Program slice view via LinearTrace.

import { Show, createResource } from "solid-js";
import type { JSX } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";
import type { SliceResult, TaintStep } from "@pb/platform";
import { AnalysisView, LinearTrace, Loading } from "@pb/platform";
import type { TraceType } from "@pb/platform";

export function SliceView(props: { store: Store<AppState, AppAction> }): JSX.Element {
  const snap = props.store.getState();

  const routeParams = () => {
    const r = snap().nav.route;
    if (r.view !== "sliceView") return null;
    return { object: r.object, proc: r.proc, line: r.line, direction: r.direction };
  };

  const key = () => {
    const p = routeParams();
    if (!p) return null;
    return `${p.object}::${p.proc}::${p.line}::${p.direction}`;
  };

  const [data] = createResource(key, async (): Promise<SliceResult> => {
    const p = routeParams();
    if (!p) throw new Error("No route params");
    const url = `/api/analysis/slice/${encodeURIComponent(p.object)}/${encodeURIComponent(p.proc)}/${p.line}?direction=${p.direction}`;
    const res = await fetch(url);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json() as Promise<SliceResult>;
  });

  function navigateToProc(object: string, proc: string, line?: number): void {
    props.store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: object, procName: proc } });
    void line;
  }

  const traceType = (): TraceType => {
    const p = routeParams();
    return p?.direction === "forward" ? "slice-forward" : "slice-backward";
  };

  const title = () => {
    const p = routeParams();
    if (!p) return "Slice";
    const dir = p.direction === "forward" ? "Forward" : "Backward";
    return `${dir} Slice — ${p.object}.${p.proc} (line ${p.line})`;
  };

  const contextLabel = () => {
    const d = data();
    if (!d) return "";
    return `${d.steps.length} statement${d.steps.length === 1 ? "" : "s"}`;
  };

  // Convert SliceStep to TaintStep shape for LinearTrace reuse.
  const adaptedSteps = (): TaintStep[] =>
    (data()?.steps ?? []).map((s) => ({
      object: s.object,
      proc_name: s.proc,
      line: s.line,
      var_name: s.var,
      step_kind: s.kind,
      description: s.text,
    }));

  return (
    <AnalysisView
      title={title()}
      contextLabel={contextLabel()}
      assumptions="Slice is computed context-insensitively. The slice may include statements reachable through dynamic dispatch that cannot be statically resolved."
    >
      <Show when={data.loading}>
        <Loading />
      </Show>

      <Show when={data.error}>
        <div class="error-banner">
          Failed to compute slice: {String(data.error)}
        </div>
      </Show>

      <Show when={!data.loading && !data.error && data()}>
        {(d) => (
          <Show
            when={d().steps.length > 0}
            fallback={
              <div class="empty-state" style={{ padding: "24px", color: "var(--text-muted)" }}>
                No statements in slice. This may mean the variable is not used/defined beyond this point.
              </div>
            }
          >
            <LinearTrace
              steps={adaptedSteps()}
              traceType={traceType()}
              traversedProcs={d().procedures_traversed}
              onNavigateToProc={navigateToProc}
            />
          </Show>
        )}
      </Show>
    </AnalysisView>
  );
}
