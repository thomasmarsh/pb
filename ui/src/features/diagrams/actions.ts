// features/diagrams/actions.ts — Diagrams feature actions (self-contained).

import type { DiagramsState } from "./types.js";
import type { NavigationAction } from "../navigation/types.js";

export type DiagramsAction =
  | { type: "select"; kind: DiagramsState["active"] }
  | { type: "params"; params: Record<string, string | number> }
  | { type: "generate" }
  | { type: "loaded"; svg: string }
  | { type: "error"; error: string }
  | { type: "navigate"; action: NavigationAction }
  ;
