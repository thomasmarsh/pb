// ObjectsDetailPanel.tsx — Router between proc/DW detail panels.

import { Show } from "solid-js";
import { useExploreStore } from "./ExploreContext.js";
import { ProcDetailPanel } from "./ProcDetailPanel.js";
import { DwDetailPanel } from "./DwDetailPanel.js";

export function ObjectsDetailPanel() {
  const store = useExploreStore();
  const snap = store.getState();
  const selectedProc = () => snap().explore.selectedProc;
  const selectedDw = () => snap().explore.selectedDw;

  return (
    <Show when={selectedProc()} fallback={
      <Show when={selectedDw()} fallback={
        <div class="explore-empty">Select a procedure or DataWindow</div>
      }>
        {(nodeId) => <DwDetailPanel nodeId={nodeId()} />}
      </Show>
    }>
      {(nodeId) => <ProcDetailPanel nodeId={nodeId()} />}
    </Show>
  );
}
