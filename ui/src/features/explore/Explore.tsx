// Explore.tsx — Detail panel for the selected proc/DW (tree lives in Layout sidebar).

import type { Store } from "@pb/core";
import type { AppState } from "../../../app/src/state.js";
import type { AppAction } from "../../../app/src/actions.js";
import { ExploreStoreContext } from "./ExploreContext.js";
import { ObjectsDetailPanel } from "./ObjectsDetailPanel.js";

export function Explore(props: { store: Store<AppState, AppAction> }) {
  return (
    <ExploreStoreContext.Provider value={props.store}>
      <ObjectsDetailPanel />
    </ExploreStoreContext.Provider>
  );
}
