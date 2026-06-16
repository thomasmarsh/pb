// ObjectsDetailPanel.tsx — Router between proc/DW/tables detail panels.

import { Show } from "solid-js";
import { useSnapshot } from "../../core/store.js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import { useExploreStore } from "./ExploreContext.js";
import { ProcDetailPanel } from "./ProcDetailPanel.js";
import { DwDetailPanel } from "./DwDetailPanel.js";
import { TableDetailPanel } from "./Tables.js";

export function ObjectsDetailPanel() {
  const store = useExploreStore();
  const snap = useSnapshot(store.state);
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

export function TablesRightPanel(props: { store: Store<AppState, AppAction> }) {
  const snap = useSnapshot(props.store.state);
  const selectedDw = () => snap().explore.selectedDw;

  return (
    <Show when={selectedDw()} fallback={<TableDetailPanel store={props.store} />}>
      {(nodeId) => <DwDetailPanel nodeId={nodeId()} />}
    </Show>
  );
}
