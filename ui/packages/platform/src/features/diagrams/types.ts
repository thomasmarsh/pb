// features/diagrams/types.ts

import type { JobPollState } from "@pb/core";
import type { DiagramKind } from "../../utils/diagram.js";

export interface DiagramsState {
  active: DiagramKind;
  job: JobPollState<string>;
  params: Record<string, string | number>;
  tableNames: string[];
  objectNames: string[];
  itemsLoaded: boolean;
}
