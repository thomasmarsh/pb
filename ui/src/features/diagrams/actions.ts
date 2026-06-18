// features/diagrams/actions.ts — Diagrams feature actions (self-contained).

import type { DiagramsState } from "./types.js";

export type DiagramsAction =
  | { tag: "select"; kind: DiagramsState["active"] }
  | { tag: "params"; params: Record<string, string | number> }
  | { tag: "generate" }
  | { tag: "loaded"; svg: string }
  | { tag: "error"; error: string }
  | { tag: "loadItems" }
  | { tag: "itemsLoaded"; tableNames: string[]; objectNames: string[] }
  ;
