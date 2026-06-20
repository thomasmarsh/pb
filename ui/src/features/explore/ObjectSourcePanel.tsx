// ObjectSourcePanel.tsx — Full object source view with proc range highlighting.

import { Show, createMemo, createEffect } from "solid-js";
import { useExploreStore } from "./ExploreContext.js";
import { SourceViewer } from "../../components/source/index.js";
import { procId } from "./TreeNodes.js";
import type { ObjectSourceResponse, ProcedureInfo } from "../../types/api.js";

export function ObjectSourcePanel(props: { objectName: string }) {
  const store = useExploreStore();
  const snap = store.getState();

  const entry = () => snap().explore.objectSourceCache[props.objectName] as ObjectSourceResponse | { error: string } | undefined;
  const highlightedProcName = () => snap().explore.highlightedProcName;

  let scrollContainer: HTMLDivElement | undefined;

  const highlightedProc = createMemo(() => {
    const name = highlightedProcName();
    const e = entry();
    if (!name || !e || "error" in e) return null;
    return (e as ObjectSourceResponse).procedures.find(p => p.name === name) ?? null;
  });

  createEffect(() => {
    const proc = highlightedProc();
    if (!proc || !scrollContainer) return;
    const startLine = proc.start_line;
    if (startLine == null) return;
    scrollContainer.scrollTop = Math.max(0, (startLine - 1) * 20.8 - 80);
  });

  function handleProcBarClick(proc: ProcedureInfo) {
    const nodeId = procId(props.objectName, proc.name);
    store.dispatch({ tag: "explore", action: { tag: "proc-select", objectName: props.objectName, procName: proc.name, nodeId } });
  }

  return (
    <Show
      when={entry() !== undefined}
      fallback={<div class="explore-empty">Loading…</div>}
    >
      <Show
        when={entry() && !("error" in (entry() as object))}
        fallback={
          <div class="explore-empty" style={{ color: "var(--red)" }}>
            {"error" in (entry() as object) ? (entry() as { error: string }).error : "Error loading source"}
          </div>
        }
      >
        <div class="explore-right-header">
          <span class="proc-name">{props.objectName}</span>
          <Show when={highlightedProcName()}>
            <span class="tree-summary" style={{ "margin-left": "8px" }}>→ {highlightedProcName()}</span>
          </Show>
        </div>
        <div class="explore-right-body" ref={scrollContainer}>
          <SourceViewer
            store={store}
            lines={(entry() as ObjectSourceResponse).lines}
            procedures={(entry() as ObjectSourceResponse).procedures}
            knownObjects={(entry() as ObjectSourceResponse).knownObjects}
            knownProcs={(entry() as ObjectSourceResponse).knownProcs}
            localSymbols={(entry() as ObjectSourceResponse).localSymbols}
            objectName={props.objectName}
            selectedProcName={highlightedProcName() ?? undefined}
            onProcBarClick={handleProcBarClick}
          />
        </div>
      </Show>
    </Show>
  );
}
