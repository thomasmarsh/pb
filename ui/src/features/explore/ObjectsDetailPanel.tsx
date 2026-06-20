// ObjectsDetailPanel.tsx — Router between object source / DW detail panels.

import { Show } from "solid-js";
import { useExploreStore } from "./ExploreContext.js";
import { ObjectSourcePanel } from "./ObjectSourcePanel.js";
import { DwDetailPanel } from "./DwDetailPanel.js";

export function ObjectsDetailPanel() {
  const store = useExploreStore();
  const snap = store.getState();
  const selectedObject = () => snap().explore.selectedObject;
  const selectedDw = () => snap().explore.selectedDw;

  return (
    <Show when={selectedObject()} fallback={
      <Show when={selectedDw()} fallback={
        <div class="explore-empty">Select an object or DataWindow</div>
      }>
        {(nodeId) => <DwDetailPanel nodeId={nodeId()} />}
      </Show>
    }>
      {(objectName) => <ObjectSourcePanel objectName={objectName()} />}
    </Show>
  );
}
