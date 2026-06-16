// ExploreContext.ts — SolidJS context for the store within the Explore feature tree.
// Provided by Explore, consumed by TreeNode, AstNode, DwDetailTree (exclusively used there).

import { createContext, useContext } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";

export const ExploreStoreContext = createContext<Store<AppState, AppAction>>();

export function useExploreStore(): Store<AppState, AppAction> {
  const store = useContext(ExploreStoreContext);
  if (!store) throw new Error("useExploreStore called outside Explore");
  return store;
}
