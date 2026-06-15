// app/actions.ts — AppAction: tagged sum type routing to each feature reducer.

import type { ExploreAction } from "../features/explore/actions.js";
import type { ObjectsAction } from "../features/objects/actions.js";
import type { DiagramsAction } from "../features/diagrams/actions.js";
import type { QueriesAction } from "../features/queries/actions.js";
import type { SearchAction } from "../features/search/actions.js";
import type { NavigationAction } from "../features/navigation/types.js";

export type AppAction =
  | { tag: "nav"; action: NavigationAction }
  | { tag: "explore"; action: ExploreAction }
  | { tag: "objects"; action: ObjectsAction }
  | { tag: "diagrams"; action: DiagramsAction }
  | { tag: "queries"; action: QueriesAction }
  | { tag: "search"; action: SearchAction };

export type Dispatch = (action: AppAction) => void;
