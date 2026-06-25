// ExploreContext.ts — SolidJS context for the store within the Explore feature tree.
// Provided by Explore, consumed by TreeNode, DwDetailPanel.

import { createContext, useContext } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../app/src/state.js";
import type { AppAction } from "../../../app/src/actions.js";

export const ExploreStoreContext = createContext<Store<AppState, AppAction>>();

export function useExploreStore(): Store<AppState, AppAction> {
  const store = useContext(ExploreStoreContext);
  if (!store) throw new Error("useExploreStore called outside Explore");
  return store;
}
