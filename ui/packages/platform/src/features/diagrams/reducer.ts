// features/diagrams/reducer.ts — Diagrams feature reducer (valtio draft style).

import { Effect, jobPollReduce, initialJobPollState, type Reducer, type JobPollEnv, type JobSubmitResult, type JobPollResult } from "@pb/core";
import type { DiagramsState } from "./types.js";
import type { DiagramsAction } from "./actions.js";
import type { TableSummary, ListObjectsResponse } from "../../types/api.js";
import type { NavigationAction } from "../navigation/types.js";

export interface DiagramsEnv {
  submitDiagramJob(kind: string, params: Record<string, string | number>): Effect<JobSubmitResult<string>>;
  pollDiagramJob(jobId: string): Effect<JobPollResult<string>>;
  getTables(): Effect<TableSummary[]>;
  getAllObjects(): Effect<ListObjectsResponse>;
  navigate(action: NavigationAction): Effect<never>;
}

export const initialDiagramsState: DiagramsState = {
  active: "inheritance", job: initialJobPollState<string>(), params: {},
  tableNames: [], objectNames: [], itemsLoaded: false,
};

function reduce(draft: DiagramsState, action: DiagramsAction, env: DiagramsEnv): Effect<DiagramsAction> | null {
  switch (action.tag) {
  case "select":
    draft.active = action.kind;
    draft.job = initialJobPollState<string>();
    return null;
  case "params":
    Object.assign(draft.params, action.params);
    return null;
  case "generate": {
    const jobEnv: JobPollEnv<string> = {
      submitJob: () => env.submitDiagramJob(draft.active, draft.params),
      pollJob: (jobId) => env.pollDiagramJob(jobId),
    };
    const eff = jobPollReduce(draft.job, { tag: "start" }, jobEnv);
    return eff ? eff.map((a): DiagramsAction => ({ tag: "job", action: a })) : null;
  }
  case "job": {
    const jobEnv: JobPollEnv<string> = {
      submitJob: () => env.submitDiagramJob(draft.active, draft.params),
      pollJob: (jobId) => env.pollDiagramJob(jobId),
    };
    const eff = jobPollReduce(draft.job, action.action, jobEnv);
    return eff ? eff.map((a): DiagramsAction => ({ tag: "job", action: a })) : null;
  }
  case "loadItems":
    if (draft.itemsLoaded) return null;
    return Effect.merge(
      env.getTables()
        .map((tables): DiagramsAction => ({
          tag: "itemsLoaded",
          tableNames: tables.map(t => t.table_name),
          objectNames: draft.objectNames,
        })),
      env.getAllObjects()
        .map((data): DiagramsAction => ({
          tag: "itemsLoaded",
          tableNames: draft.tableNames,
          objectNames: data.items.map(o => o.name),
        })),
    );
  case "itemsLoaded":
    if (action.tableNames.length > 0) draft.tableNames = action.tableNames;
    if (action.objectNames.length > 0) draft.objectNames = action.objectNames;
    if (draft.tableNames.length > 0 && draft.objectNames.length > 0) draft.itemsLoaded = true;
    return null;
  default:
    return null;
  }
}

export const diagramsReducer: Reducer<DiagramsState, DiagramsAction, DiagramsEnv> = reduce;
