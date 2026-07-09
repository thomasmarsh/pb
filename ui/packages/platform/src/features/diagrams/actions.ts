// features/diagrams/actions.ts — Diagrams feature actions (self-contained).

import type { JobPollAction } from "@pb/core";
import type { DiagramsState } from "./types.js";

export type DiagramsAction =
  | { tag: "select"; kind: DiagramsState["active"] }
  | { tag: "params"; params: Record<string, string | number> }
  | { tag: "generate" }
  | { tag: "job"; action: JobPollAction<string> }
  | { tag: "loadItems" }
  | { tag: "itemsLoaded"; tableNames: string[]; objectNames: string[] }
  ;
