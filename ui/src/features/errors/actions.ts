// features/errors/actions.ts — Errors feature actions (self-contained).

import type { ParseErrorRow } from "../../types/api.js";
import type { ErrorKindFilter } from "./types.js";

export type ErrorsAction =
  | { type: "load" }
  | { type: "loaded"; items: ParseErrorRow[]; total: number }
  | { type: "setFilterKind"; kind: ErrorKindFilter }
  | { type: "setQuery"; query: string }
  | { type: "select"; row: ParseErrorRow | null }
  | { type: "error"; error: string }
  ;
