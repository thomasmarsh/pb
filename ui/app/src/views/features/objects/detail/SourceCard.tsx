// SourceCard.tsx — Source file viewer with error/empty states.

import { Show } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../../state.js";
import type { AppAction } from "../../../../actions.js";
import type { ObjectSourceResponse, ProcedureInfo, ResolvedCallInfo, ResolvedVarRefInfo } from "@pb/platform";
import { SourceViewer } from "../../../components/source/index.js";
import type { ContextActions } from "../../../components/source/index.js";

export function SourceCard(props: {
  store: Store<AppState, AppAction>;
  file: string;
  objectName: string;
  sourceDetail: ObjectSourceResponse | { error: string } | null;
  selectedProcName?: string;
  contextActions?: ContextActions;
}) {
  const snap = props.store.getState();

  const hasLines = () => {
    const s = props.sourceDetail;
    return s && "lines" in s && s.lines && s.lines.length > 0;
  };

  const sliceHighlight = (): { lines: Set<number>; label: string } | null => {
    const sh = snap().objects.sliceHighlight;
    if (!sh || "error" in sh || sh.object !== props.objectName) return null;
    const lines = new Set(sh.steps.filter((s) => s.object === props.objectName).map((s) => s.line));
    const dir = sh.direction === "forward" ? "Forward" : "Backward";
    const count = sh.steps.length;
    return { lines, label: `${dir} slice from ${sh.proc}:${sh.origin.line} — ${count} statement${count === 1 ? "" : "s"}` };
  };

  return (
    <div class="card">
      <div class="source-file-header">
        <div class="card-header"><h3>Source</h3></div>
        <div class="source-file-path">{props.file}</div>
      </div>
      <Show
        when={hasLines()}
        fallback={
          <Show when={props.sourceDetail}>
            {"error" in (props.sourceDetail as object)
              ? <p style={{ color: "var(--red)", "font-size": "12px" }}>{(props.sourceDetail as { error: string }).error}</p>
              : <p style={{ color: "var(--text-muted)", "font-size": "12px" }}>Source not available — re-index to restore it.</p>
            }
          </Show>
        }
      >
        <SourceViewer
          store={props.store}
          lines={(props.sourceDetail as { lines: string[] }).lines}
          procedures={(props.sourceDetail as { procedures: ProcedureInfo[] }).procedures}
          knownObjects={(props.sourceDetail as { knownObjects: { name: string; kind: string }[] }).knownObjects}
          resolvedCalls={(props.sourceDetail as { resolvedCalls: ResolvedCallInfo[] }).resolvedCalls}
          resolvedVarRefs={(props.sourceDetail as { resolvedVarRefs?: ResolvedVarRefInfo[] }).resolvedVarRefs}
          objectName={props.objectName}
          selectedProcName={props.selectedProcName}
          contextActions={props.contextActions}
          sliceHighlight={sliceHighlight()}
          onClearSliceHighlight={() => props.store.dispatch({ tag: "objects", action: { tag: "clear-slice-highlight" } })}
        />
      </Show>
    </div>
  );
}
