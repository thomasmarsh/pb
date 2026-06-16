// features/errors/types.ts

import type { ParseErrorRow } from "../../types/api.js";

export type ErrorKindFilter = "all" | "powerscript" | "sql";

export interface ErrorsState {
  items: ParseErrorRow[];
  total: number;
  loading: boolean;
  filterKind: ErrorKindFilter;
  query: string;
  selected: ParseErrorRow | null;
}
