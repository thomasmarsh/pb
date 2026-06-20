// DwDetailPanel.tsx — DataWindow detail panel (explore sidebar).

import { useExploreStore } from "./ExploreContext.js";
import type { DwDetailResponse } from "../../types/api.js";
import { DetailShell } from "../../components/detail/DetailShell.js";
import { DwDetailCore } from "../datawindows/DWDetail.js";

export function DwDetailPanel(props: { nodeId: string }) {
  const store = useExploreStore();
  const snap = store.getState();
  const entry = () => snap().explore.dwCache[props.nodeId];

  return (
    <DetailShell<DwDetailResponse> entry={entry()} loadingMsg="Loading DataWindow...">
      {(d) => <DwDetailCore d={d} store={store} />}
    </DetailShell>
  );
}
