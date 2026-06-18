// features/search/reducer.ts — Search feature reducer (valtio draft style).

import { Effect } from "../../core/effect.js";
import type { Reducer } from "../../core/reducer.js";
import type { SearchState } from "./types.js";
import type { SearchAction } from "./actions.js";
import type { SearchResponse } from "../../types/api.js";
import type { NavigationAction } from "../navigation/types.js";

export interface SearchEnv {
  search(q: string): Effect<SearchResponse>;
  navigate(action: NavigationAction): Effect<never>;
}

export const initialSearchState: SearchState = {
  term: "",
  results: null,
  loading: false,
  recentSearches: [],
  overlayOpen: false,
  overlayTerm: "",
  overlayResults: null,
  overlayLoading: false,
};

const MAX_RECENT = 5;

function addRecent(recent: string[], term: string): string[] {
  const deduped = [term, ...recent.filter((r) => r !== term)];
  return deduped.slice(0, MAX_RECENT);
}

function reduce(draft: SearchState, action: SearchAction, env: SearchEnv): Effect<SearchAction> | null {
  switch (action.type) {
  case "term":
    draft.term = action.term;
    if (action.term.length < 2) return null;
    draft.recentSearches = addRecent(draft.recentSearches, action.term);
    return env.search(action.term).map((data): SearchAction => ({ type: "loaded", data }));

  case "loaded":
    draft.results = action.data;
    draft.loading = false;
    return null;

  case "overlay-open":
    draft.overlayOpen = true;
    draft.overlayTerm = "";
    draft.overlayResults = null;
    return null;

  case "overlay-close":
    draft.overlayOpen = false;
    return null;

  case "overlay-term":
    draft.overlayTerm = action.term;
    if (action.term.length < 2) {
      draft.overlayResults = null;
      return null;
    }
    draft.overlayLoading = true;
    return env.search(action.term).map((data): SearchAction => ({ type: "overlay-loaded", data }));

  case "overlay-loaded":
    draft.overlayResults = action.data;
    draft.overlayLoading = false;
    return null;

  default:
    return null;
  }
}

export const searchReducer: Reducer<SearchState, SearchAction, SearchEnv> = reduce;
