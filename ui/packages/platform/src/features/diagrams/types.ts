// features/diagrams/types.ts

import type { DiagramKind } from "../../utils/diagram.js";

export interface DiagramsState {
  active: DiagramKind;
  svg: string | null;
  loading: boolean;
  params: Record<string, string | number>;
  error?: string;
  tableNames: string[];
  objectNames: string[];
  itemsLoaded: boolean;
}
