// features/errors/types.ts

import type { ParseErrorRow } from "../../types/api.js";

export type ErrorKindFilter = "all" | "powerscript" | "sql";

export const PAGE_SIZE = 100;

export interface ErrorsState {
  items: ParseErrorRow[];
  total: number;
  loading: boolean;
  filterKind: ErrorKindFilter;
  query: string;
  page: number;
  selected: ParseErrorRow | null;
}
