// features/tables/reducer.ts

import { Effect, type Reducer } from "@pb/core";
import type { TablesState } from "./types.js";
import type { TablesAction } from "./actions.js";
import type { SchemaSummary, TableSummary, TableDetail, ColumnUsageResponse, CoUpdateRitualsResponse, DecompositionCandidatesResponse, ColumnAffinityResponse, StatsResponse } from "../../types/api.js";
import type { NavigationAction } from "../navigation/types.js";

export type { TablesState };
export { initialTablesState } from "./types.js";

export interface TablesEnv {
  getSchemas(): Effect<SchemaSummary[]>;
  getTables(namespace?: string): Effect<TableSummary[]>;
  getTableDetail(name: string, namespace?: string): Effect<TableDetail>;
  getColumnUsage(): Effect<ColumnUsageResponse>;
  getCoUpdateRituals(): Effect<CoUpdateRitualsResponse>;
  getDecompositionCandidates(table: string, namespace?: string): Effect<DecompositionCandidatesResponse>;
  getColumnAffinity(table: string, namespace?: string): Effect<ColumnAffinityResponse>;
  getStats(): Effect<StatsResponse>;
  navigate(action: NavigationAction): Effect<never>;
}

function errMsg(e: unknown): string { return e instanceof Error ? e.message : String(e); }

// Shared building blocks — each fires its effect and mutates draft's loading
// flags, or returns null if there's nothing to do. Reused by both the
// standalone actions (schemas-load/stats-load/search) and "mount" (which
// fires all three together via Effect.merge) so the sequencing lives once,
// in the reducer, not scattered across component dispatches.

function fireSchemasLoad(draft: TablesState, env: TablesEnv): Effect<TablesAction> | null {
  if (draft.schemas.length > 0 || draft.schemasLoading) return null;
  draft.schemasLoading = true;
  return env.getSchemas()
    .map((schemas): TablesAction => ({ tag: "schemas-loaded", schemas }))
    .catch((e): TablesAction => ({ tag: "schemas-error", error: errMsg(e) }));
}

function fireStatsLoad(draft: TablesState, env: TablesEnv): Effect<TablesAction> | null {
  if (draft.defaultNamespace !== null || draft.statsLoading) return null;
  draft.statsLoading = true;
  return env.getStats()
    .map((stats): TablesAction => ({ tag: "stats-loaded", defaultNamespace: stats.default_namespace ?? null }))
    .catch((): TablesAction => ({ tag: "stats-error" }));
}

// Fires the table-list fetch for q/namespace, navigating and resetting q.
// Used for a fresh load (mount, or the default namespace arriving after
// mount) — unconditional, unlike fireSearchIfNeeded below.
function fireSearch(draft: TablesState, env: TablesEnv, q: string, namespace: string | undefined): Effect<TablesAction> {
  draft.q = q;
  draft.namespace = namespace ?? null;
  draft.loading = true;
  env.navigate({
    tag: "navigate",
    route: namespace ? { view: "tables", namespace } : { view: "tables" },
  });
  return env.getTables(namespace)
    .map((items): TablesAction => ({ tag: "loaded", items }));
}

// Mount-time variant: skips the fetch entirely if the view already has
// matching data loaded (e.g. remounting after navigating back).
function fireSearchIfNeeded(draft: TablesState, env: TablesEnv, namespace: string | undefined): Effect<TablesAction> | null {
  const target = namespace ?? null;
  if (draft.items.length > 0 && draft.namespace === target) return null;
  return fireSearch(draft, env, "", namespace);
}

function reduce(draft: TablesState, action: TablesAction, env: TablesEnv): Effect<TablesAction> | null {
  switch (action.tag) {
  case "mount": {
    const effects = [
      fireSchemasLoad(draft, env),
      fireStatsLoad(draft, env),
      fireSearchIfNeeded(draft, env, action.namespace),
    ].filter((e): e is Effect<TablesAction> => e !== null);
    return effects.length > 0 ? Effect.merge(...effects) : null;
  }
  case "schemas-load":
    return fireSchemasLoad(draft, env);
  case "schemas-loaded":
    draft.schemas = action.schemas;
    draft.schemasLoading = false;
    return null;
  case "schemas-error":
    draft.schemasLoading = false;
    return null;
  case "stats-load":
    return fireStatsLoad(draft, env);
  case "stats-loaded": {
    draft.defaultNamespace = action.defaultNamespace;
    draft.statsLoading = false;
    // The route didn't pin a namespace before the default arrived — adopt
    // it now, same as if the route had specified it from the start.
    if (action.defaultNamespace && draft.namespace === null) {
      return fireSearch(draft, env, draft.q, action.defaultNamespace);
    }
    return null;
  }
  case "stats-error":
    draft.statsLoading = false;
    return null;
  case "filter":
    draft.q = action.q;
    return null;
  case "search":
    return fireSearch(draft, env, action.q, action.namespace);
  case "loaded":
    draft.items = action.items;
    draft.total = action.items.length;
    draft.loading = false;
    return null;
  case "select":
    draft.detail = null;
    draft.error = null;
    draft.decompositionCandidates = null;
    draft.decompositionCandidatesLoading = false;
    draft.columnAffinity = null;
    draft.columnAffinityLoading = false;
    env.navigate({
      tag: "navigate",
      route: action.namespace
        ? { view: "tableDetail", name: action.name, namespace: action.namespace }
        : { view: "tableDetail", name: action.name },
    });
    return env.getTableDetail(action.name, action.namespace)
      .map((detail): TablesAction => ({ tag: "detail-loaded", detail }))
      .catch((e): TablesAction => ({ tag: "detail-error", error: errMsg(e) }));
  case "detail-loaded":
    draft.detail = action.detail;
    draft.loading = false;
    return null;
  case "detail-error":
    draft.error = action.error;
    draft.loading = false;
    return null;
  case "back":
    draft.detail = null;
    draft.error = null;
    env.navigate({
      tag: "navigate",
      route: draft.namespace ? { view: "tables", namespace: draft.namespace } : { view: "tables" },
    });
    return null;
  case "column-usage-load": {
    if (draft.columnUsage || draft.columnUsageLoading) return null;
    draft.columnUsageLoading = true;
    return env.getColumnUsage()
      .map((data): TablesAction => ({ tag: "column-usage-loaded", data }))
      .catch((e): TablesAction => ({ tag: "column-usage-error", error: errMsg(e) }));
  }
  case "column-usage-loaded":
    draft.columnUsage = action.data;
    draft.columnUsageLoading = false;
    return null;
  case "column-usage-error":
    draft.columnUsage = { error: action.error };
    draft.columnUsageLoading = false;
    return null;
  case "co-update-rituals-load": {
    if (draft.coUpdateRituals || draft.coUpdateRitualsLoading) return null;
    draft.coUpdateRitualsLoading = true;
    return env.getCoUpdateRituals()
      .map((data): TablesAction => ({ tag: "co-update-rituals-loaded", data }))
      .catch((e): TablesAction => ({ tag: "co-update-rituals-error", error: errMsg(e) }));
  }
  case "co-update-rituals-loaded":
    draft.coUpdateRituals = action.data;
    draft.coUpdateRitualsLoading = false;
    return null;
  case "co-update-rituals-error":
    draft.coUpdateRituals = { error: action.error };
    draft.coUpdateRitualsLoading = false;
    return null;
  case "decomposition-candidates-load": {
    const already = draft.decompositionCandidates
      && "table" in draft.decompositionCandidates
      && draft.decompositionCandidates.table === action.tableName;
    if (already || draft.decompositionCandidatesLoading) return null;
    draft.decompositionCandidatesLoading = true;
    return env.getDecompositionCandidates(action.tableName, action.namespace)
      .map((data): TablesAction => ({ tag: "decomposition-candidates-loaded", data }))
      .catch((e): TablesAction => ({ tag: "decomposition-candidates-error", error: errMsg(e) }));
  }
  case "decomposition-candidates-loaded":
    draft.decompositionCandidates = action.data;
    draft.decompositionCandidatesLoading = false;
    return null;
  case "decomposition-candidates-error":
    draft.decompositionCandidates = { error: action.error };
    draft.decompositionCandidatesLoading = false;
    return null;
  case "column-affinity-load": {
    const already = draft.columnAffinity
      && "table" in draft.columnAffinity
      && draft.columnAffinity.table === action.tableName;
    if (already || draft.columnAffinityLoading) return null;
    draft.columnAffinityLoading = true;
    return env.getColumnAffinity(action.tableName, action.namespace)
      .map((data): TablesAction => ({ tag: "column-affinity-loaded", data }))
      .catch((e): TablesAction => ({ tag: "column-affinity-error", error: errMsg(e) }));
  }
  case "column-affinity-loaded":
    draft.columnAffinity = action.data;
    draft.columnAffinityLoading = false;
    return null;
  case "column-affinity-error":
    draft.columnAffinity = { error: action.error };
    draft.columnAffinityLoading = false;
    return null;
  default:
    return null;
  }
}

export const tablesReducer: Reducer<TablesState, TablesAction, TablesEnv> = reduce;
