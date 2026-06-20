// features/objects/types.ts

import type { ObjectRow, ObjectDetailResponse, ObjectSourceResponse, ProcedureDetailResponse, ProcedureListItem } from "../../types/api.js";
import type { Face } from "../../components/ui/FaceToggle.js";

export type { Face };

export interface ScrollPair { source: number; analysis: number; }

export interface ObjectsState {
  items: ObjectRow[];
  total: number;
  q: string;
  kind: string;
  sort: string;
  order: "asc" | "desc";
  offset: number;
  loading: boolean;
  detail: ObjectDetailResponse | { error: string } | null;
  sourceDetail: ObjectSourceResponse | { error: string } | null;
  procedureDetail: ProcedureDetailResponse | { error: string } | null;
  allObjects: ObjectRow[];
  objectFace: Face;
  objectScrollPos: Record<string, ScrollPair>;
  // Procedures list screen
  proceduresList: ProcedureListItem[] | null;
  proceduresListLoading: boolean;
  proceduresListQ: string;
  proceduresListKind: string;
  proceduresListSort: "name" | "object" | "cyclomatic" | "caller_count";
  proceduresListOrder: "asc" | "desc";
}
