// DwDetailPanel.tsx — DataWindow detail panel (explore sidebar).

import { useExploreStore } from "./ExploreContext.js";
import type { DwDetailResponse } from "@pb/platform";
import { DetailShell } from "@pb/platform";
import { DwDetailCore } from "../datawindows/DWDetail.js";

export function DwDetailPanel(props: { nodeId: string }) {
  const store = useExploreStore();
  const snap = store.getState();
  const entry = () => snap().explore.dwCache[props.nodeId];
  const layout = () => snap().explore.dwLayoutCache[props.nodeId] ?? null;

  return (
    <DetailShell<DwDetailResponse> entry={entry()} loadingMsg="Loading DataWindow...">
      {(d) => <DwDetailCore d={d} layout={layout()} store={store} />}
    </DetailShell>
  );
}
