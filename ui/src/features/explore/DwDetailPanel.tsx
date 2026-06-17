// DwDetailPanel.tsx — DataWindow detail panel.

import { useExploreStore } from "./ExploreContext.js";
import type { DwExploreDetail } from "../../types/api.js";
import { DetailShell } from "../../components/DetailShell.js";
import { DwDetailTree } from "./DwDetailTree.js";

export function DwDetailPanel(props: { nodeId: string }) {
  const store = useExploreStore();
  const snap = store.getState();
  const entry = () => snap().explore.dwCache[props.nodeId];
  const dwName = () => props.nodeId.replace(/^dw:/, "");

  return (
    <DetailShell<DwExploreDetail> entry={entry()} loadingMsg="Loading DataWindow...">
      {(d) => (
        <>
          <div class="explore-right-header">
            <span class="badge badge-dw">datawindow</span>
            <span class="proc-name">{dwName()}</span>
            <span class="proc-params">{d.controls.length} controls</span>
          </div>
          <div class="explore-right-body">
            <DwDetailTree data={d} />
          </div>
        </>
      )}
    </DetailShell>
  );
}
