// features/errors/actions.ts — Errors feature actions (self-contained).

import type { ParseErrorRow, TypeCoverageResponse } from "../../types/api.js";
import type { ErrorKindFilter } from "./types.js";

export type ErrorsAction =
  | { tag: "load" }
  | { tag: "loaded"; items: ParseErrorRow[]; total: number }
  | { tag: "setFilterKind"; kind: ErrorKindFilter }
  | { tag: "setQuery"; query: string }
  | { tag: "setPage"; page: number }
  | { tag: "select"; row: ParseErrorRow | null }
  | { tag: "error"; error: string }
  | { tag: "typeCoverageLoaded"; data: TypeCoverageResponse }
  | { tag: "typeCoverageError"; error: string }
  ;
