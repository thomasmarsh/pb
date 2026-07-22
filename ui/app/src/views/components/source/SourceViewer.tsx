// SourceViewer.tsx — Source code viewer with cross-linked identifiers.

import { Show, createSignal, createMemo } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";
import type { ContextMenuTarget, ContextActions } from "./SourceContextMenu.js";
import { SourceContextMenu } from "./SourceContextMenu.js";
import {
  SourceView,
  buildProcCountMap, buildProcFirstLine,
  procSelectedRange, procedureAtLine,
  type ProcedureInfo, type ResolvedCallInfo, type ResolvedVarRefInfo, type SourceLinkTarget,
} from "@pb/platform";

interface SourceViewerProps {
  lines: string[];
  procedures: ProcedureInfo[];
  knownObjects: { name: string; kind: string }[];
  resolvedCalls: ResolvedCallInfo[];
  resolvedVarRefs?: ResolvedVarRefInfo[];
  objectName: string;
  selectedProcName?: string;
  onProcBarClick?: (proc: ProcedureInfo) => void;
  contextActions?: ContextActions;
  sliceHighlight?: { lines: Set<number>; label: string } | null;
  onClearSliceHighlight?: () => void;
}

export function SourceViewer(props: { store: Store<AppState, AppAction> } & SourceViewerProps) {
  const store = props.store;
  const [menuTarget, setMenuTarget] = createSignal<ContextMenuTarget | null>(null);

  const procCountMap = createMemo(() => buildProcCountMap(props.procedures));
  const procFirstLine = createMemo(() => buildProcFirstLine(props.procedures));
  const selectedRange = createMemo(() => procSelectedRange(props.procedures, props.selectedProcName));

  // Selected-procedure range, as a set of absolute line numbers — rendered
  // per-line by SourceView so the highlight can never drift from the gutter.
  const rangeLines = createMemo<Set<number> | null>(() => {
    const r = selectedRange();
    if (!r) return null;
    const s = new Set<number>();
    for (let n = r.start; n <= r.end; n++) s.add(n);
    return s;
  });

  const dimLines = createMemo<Set<number> | null>(() => props.sliceHighlight?.lines ?? null);

  function handleLinkClick(linkType: "object" | "procedure" | "var", linkName: string, target: SourceLinkTarget) {
    if (linkType === "object") {
      store.dispatch({ tag: "objects", action: { tag: "select", name: linkName } });
    } else if (linkType === "procedure") {
      const call = target as ResolvedCallInfo | undefined;
      store.dispatch(call?.target_object && call?.target_proc
        ? { tag: "objects", action: { tag: "proc-select", objectName: call.target_object, procName: call.target_proc } }
        : { tag: "objects", action: { tag: "select", name: linkName } }
      );
    }
  }

  function handleLinkContextMenu(
    e: MouseEvent,
    linkType: "object" | "procedure" | "var",
    linkName: string,
    sourceLine: number,
    target: SourceLinkTarget,
  ) {
    const call = linkType === "procedure" ? (target as ResolvedCallInfo | undefined) : undefined;
    const counts = call ? procCountMap().get(call.to_name.toLowerCase()) : undefined;
    setMenuTarget({
      linkType, linkName, x: e.clientX, y: e.clientY,
      sourceLine,
      callerCount: counts?.caller_count,
      calleeCount: counts?.callee_count,
      procObject: call?.target_object ?? undefined,
      viewedProcName: procedureAtLine(props.procedures, sourceLine)?.name,
    });
  }

  return (
    <div class="source-viewer-wrapper">
      <Show when={props.sliceHighlight}>
        {(sh) => (
          <div class="source-slice-banner">
            <span>{sh().label}</span>
            <button onClick={() => props.onClearSliceHighlight?.()}>Clear</button>
          </div>
        )}
      </Show>
      <SourceView
        lines={props.lines}
        knownObjects={props.knownObjects}
        resolvedCalls={props.resolvedCalls}
        resolvedVarRefs={props.resolvedVarRefs}
        procedures={props.procedures}
        objectName={props.objectName}
        rangeLines={rangeLines()}
        procFirstLine={procFirstLine()}
        dimLines={dimLines()}
        selectedProcName={props.selectedProcName}
        onProcBarClick={props.onProcBarClick}
        onLinkClick={handleLinkClick}
        onLinkContextMenu={handleLinkContextMenu}
        scrollToLine={selectedRange()?.start ?? null}
      />
      <SourceContextMenu
        target={menuTarget()}
        store={store}
        objectName={props.objectName}
        contextActions={props.contextActions}
        onClose={() => setMenuTarget(null)}
      />
    </div>
  );
}
