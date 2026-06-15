// features/search/reducer.ts — Search feature reducer (valtio draft style).

import { Effect } from "../../core/effect.js";
import type { Reducer } from "../../core/reducer.js";
import type { SearchState } from "./types.js";
import type { SearchAction } from "./actions.js";
import type { SearchResponse } from "../../types/api.js";

export interface SearchEnv {
  search(q: string): Effect<SearchResponse>;
}

export const initialSearchState: SearchState = {
  term: "", results: null, loading: false,
};

function reduce(draft: SearchState, action: SearchAction, env: SearchEnv): Effect<SearchAction> | null {
  switch (action.type) {
  case "term":
    draft.term = action.term;
    if (action.term.length < 2) return null;
    return env.search(action.term).map((data): SearchAction => ({ type: "loaded", data }));
  case "loaded":
    draft.results = action.data;
    draft.loading = false;
    return null;
  default:
    return null;
  }
}

export const searchReducer: Reducer<SearchState, SearchAction, SearchEnv> = reduce;
