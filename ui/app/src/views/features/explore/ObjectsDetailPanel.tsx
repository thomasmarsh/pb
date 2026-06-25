// ObjectsDetailPanel.tsx — Shows DW detail panel when a DW is selected in the tree.

import { Show } from "solid-js";
import { useExploreStore } from "./ExploreContext.js";
import { DwDetailPanel } from "./DwDetailPanel.js";

export function ObjectsDetailPanel() {
  const store = useExploreStore();
  const snap = store.getState();
  const selectedDw = () => snap().explore.selectedDw;

  return (
    <Show when={selectedDw()} fallback={
      <div class="explore-empty">Select an object or DataWindow</div>
    }>
      {(nodeId) => <DwDetailPanel nodeId={nodeId()} />}
    </Show>
  );
}
