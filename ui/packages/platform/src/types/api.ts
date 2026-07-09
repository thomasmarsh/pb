// API types derived from DuckDB schema and api.py routes.

import type { WireTerm } from "@pb/interpreter";

// ── DuckDB table rows ───────────────────────────────────────────────────────

export interface ObjectRow {
  name: string;
  kind: "powerscript" | "datawindow" | "project" | string;
  file: string;
  ancestor: string | null;
}

export interface ProcedureRow {
  object: string;
  proc_type: "function" | "subroutine" | "event" | "on";
  name: string;
  modifiers: string | null;
  params: string | null;
  return_type: string | null;
  start_line: number | null;
  end_line: number | null;
  cyclomatic: number | null;
}

export interface ObjectMetrics {
  object: string;
  in_degree: number;
  out_degree: number;
  betweenness: number;
  pagerank: number;
  max_cyclomatic: number;
  avg_cyclomatic: number;
  dit: number;
  cbo: number;
}

export interface DwControlRow {
  control_name: string;
  control_type: string;
  band: string;
  x: number | null;
  y: number | null;
  width: number | null;
  height: number | null;
  expression: string | null;
  tab_seq: number | null;
  source_line: number | null;
}

// ── API response shapes ─────────────────────────────────────────────────────

export interface ListObjectsResponse {
  total: number;
  offset: number;
  limit: number;
  items: ObjectRow[];
}

export interface ObjectDetailResponse extends ObjectRow {
  metrics: ObjectMetrics | null;
  procedures: ProcedureRow[];
  ancestors: string[];
  descendants: string[];
  callers: string[];
  callees: string[];
  dws_used?: string[];
  tables_accessed?: string[];
  loading?: boolean;
}

export interface ProcedureInfo {
  name: string;
  proc_type: string;
  owner?: string | null;
  modifiers: string | null;
  params: string | null;
  return_type: string | null;
  start_line: number | null;
  end_line: number | null;
  cyclomatic: number | null;
  caller_count?: number;
  callee_count?: number;
}

export interface KnownProcInfo {
  name: string;
  object: string;
  proc_type: string;
  params: string | null;
  return_type: string | null;
  modifiers: string | null;
  start_line: number | null;
  end_line: number | null;
  cyclomatic: number | null;
}

export interface LocalSymbolInfo {
  proc_name: string;
  var_name: string;
  raw_type: string;
  resolved_kind: string;
  resolved_target: string | null;
  is_parameter: boolean;
}

export interface ObjectSourceResponse {
  file: string;
  lines: string[];
  procedures: ProcedureInfo[];
  knownObjects: { name: string; kind: string }[];
  knownProcs: KnownProcInfo[];
  localSymbols?: LocalSymbolInfo[];
  loading?: boolean;
}

export interface ProcCallerInfo {
  object: string;
  proc: string;
}

export interface ProcedureDetailResponse extends ProcedureRow {
  file?: string;
  source_original: string | null;
  callers?: ProcCallerInfo[];
  callees?: string[];
  sql_statements?: SqlStatementRow[];
  activeTab?: string;
  loading?: boolean;
}

export interface WiringDiagramResponse {
  term: WireTerm;
  sharedBlocks: Record<string, WireTerm>;
  sourceOriginal: string | null;
  procStartLine: number | null;
}

export interface CfgNodeState {
  blockId: string;
  state: string;
}

export interface CfgBlockDetail {
  blockId: string;
  firstLine: number | null;
  lastLine: number | null;
  stmts: string[];
}

export interface CfgDiagramResponse {
  svg: string;
  nodeStates: CfgNodeState[];
  blocks: CfgBlockDetail[];
  sourceOriginal: string | null;
  procStartLine: number | null;
}

export interface DwDetailResponse {
  name: string;
  file: string;
  controls: DwControlRow[];
  retrieve_tables: string[];
  retrieve_columns: { column_fqn: string; table_name: string; column_name: string }[];
  retrieve_where: { idx: number; exp1: string; op: string; exp2: string; logic: string }[];
  arguments: { arg_name: string; arg_type: string }[];
  source: string | null;
  used_by_objects?: string[];
  used_by_procs?: { object: string; proc: string }[];
  loading?: boolean;
}

export interface ProcedureListItem {
  object: string;
  proc_type: string;
  name: string;
  modifiers: string | null;
  params: string | null;
  return_type: string | null;
  cyclomatic: number | null;
  caller_count: number;
}

export interface SearchResponse {
  objects: ObjectRow[];
  procedures: { object: string; proc_type: string; name: string; modifiers: string; start_line: number }[];
  datawindows: { dw_name: string; control_name: string; control_type: string }[];
  tables: { table_name: string; dw_count: number; ps_count: number }[];
}

export interface StatsResponse {
  default_namespace?: string | null;
  objects: number;
  procedures: number;
  dw_controls: number;
  dw_retrieve_tables: number;
  dw_retrieve_columns: number;
  inherits: number;
  calls: number;
  object_metrics: number;
  tables: number;
  by_kind: { kind: string; count: number }[];
  top_complex: ProcedureRow[];
  top_pagerank: { object: string; pagerank: number; in_degree: number; out_degree: number }[];
  files_indexed?: number;
  parse_error_count?: number;
  taint_path_count?: number;
  resolved_type_count?: number;
  resolved_call_count?: number;
  dead_dw?: number;
  ddl_loaded?: boolean;
  unenforced_fk_count?: number;
  unused_fk_count?: number;
  corroborated_fk_count?: number;
  dead_column_count?: number;
  co_update_pair_count?: number;
  co_update_violation_count?: number;
}

export interface QueryParam {
  name: string;
  type: string;
  default: string | null;
}

export interface QueryDef {
  name: string;
  description: string;
  params: QueryParam[];
  sql?: string;
}

export interface QueryColumn {
  name: string;
  entity_type: string | null;
}

export interface QueryResult {
  columns: QueryColumn[];
  rows: Record<string, unknown>[];
}

// ── Tables ───────────────────────────────────────────────────────────────────

export interface SchemaSummary {
  namespace:   string;
  table_count: number;
}

export interface TableSummary {
  table_name: string;
  namespace?: string;
  dw_count:   number;
  ps_count:   number;
  file_count: number;
}

export interface TableProcedureRef {
  object:    string;
  proc_name: string | null;
  operation: string;
}

export interface ColumnPsRef {
  object:    string;
  proc_name: string | null;
  operation: string;
}

export interface ColumnDetail {
  column:      string;
  dw_readers:  string[];
  ps_readers:  ColumnPsRef[];
  ps_writers:  ColumnPsRef[];
  read_count:  number;
  write_count: number;
}

export interface ImpactDirectRef {
  object:    string;
  source:    "datawindow" | "powerscript";
  operation: string;
}

export interface ImpactInheritedRef {
  descendant: string;
  ancestor:   string;
  depth:      number;
}

export interface TableImpact {
  direct:    ImpactDirectRef[];
  inherited: ImpactInheritedRef[];
}

export interface TableDetail {
  table_name:     string;
  namespace?:     string;
  dw_count:       number;
  ps_count:       number;
  datawindows:    { dw_name: string; file: string }[];
  columns:        { dw_name: string; column_fqn: string; column_name: string }[];
  columns_detail: ColumnDetail[];
  where:          { dw_name: string; idx: number; exp1: string; op: string; exp2: string; logic: string }[];
  procedures:     TableProcedureRef[];
  impact:         TableImpact;
}

// ── Explore tree ─────────────────────────────────────────────────────────────

export interface ExploreProcedure {
  object: string;
  proc_type: string;
  name: string;
  modifiers: string | null;
  params: string | null;
  return_type: string | null;
  start_line: number | null;
  end_line: number | null;
  cyclomatic: number | null;
}

export interface ExploreObject {
  name: string;
  kind: string;
  file: string;
  procedures: ExploreProcedure[];
}

export interface ExploreLibrary {
  name: string;
  objects: ExploreObject[];
}

export interface ExploreTreeResponse {
  libraries: ExploreLibrary[];
}

export interface SqlStatementRow {
  line: number;
  operation: string;
  raw_sql: string;
  formatted_sql: string;
  tables: string[] | null;
  columns: string[] | null;
  has_into: boolean;
  has_cursor: boolean;
  parse_ok: boolean;
}

export interface ParseErrorRow {
  file: string;
  error_kind: "powerscript" | "sql";
  message: string;
  object: string | null;
  proc_name: string | null;
  line: number | null;
  snippet: string | null;
}

export interface ErrorListResponse {
  total: number;
  offset: number;
  limit: number;
  items: ParseErrorRow[];
}

export interface LibraryObject {
  name: string;
  kind: string;
  proc_count: number;
}

export interface LibraryDetailResponse {
  name: string;
  objects: LibraryObject[];
  object_count: number;
  uncalled_proc_count: number;
}

export interface DeadCodeItem {
  name: string;
  object: string;
  proc_type: string;
  cyclomatic: number | null;
  caller_count_naive: number;
  caller_count_scoped: number;
}

export interface DeadCodeResponse {
  items: DeadCodeItem[];
  total: number;
}

// ── Taint analysis ───────────────────────────────────────────────────────────

export interface TaintEndpoint {
  object: string;
  proc: string;
  var: string;
  line: number | null;
  type: string;
}

export interface TaintPathSummary {
  id: number;
  severity: string;
  category: string;
  source: TaintEndpoint;
  sink: TaintEndpoint & { severity: string };
}

export interface TaintStep {
  object: string;
  proc_name: string;
  line: number | null;
  var_name: string;
  step_kind: string; // 'source' | 'def' | 'arg' | 'return' | 'global' | 'sink'
  description: string;
}

export interface TaintPathDetail extends TaintPathSummary {
  steps: TaintStep[];
}

export interface TaintPathsResponse {
  paths: TaintPathSummary[];
  total: number;
}

// ── Schema category (Plan 148/153) ───────────────────────────────────────────

export interface ColumnTouch {
  namespace: string | null;
  table: string;
  column: string;
  is_write: boolean;
}

export interface FilterTouch {
  namespace: string | null;
  table: string;
  column: string;
  op: string;
  values_json: string | null;
}

export interface UnresolvedRef {
  line: number;
  raw_name: string;
}

export interface StatementFootprint {
  line: number;
  file: string;
  columns: ColumnTouch[];
  filters: FilterTouch[];
}

export interface ProcedureFootprintResponse {
  object: string;
  proc_name: string;
  statements: StatementFootprint[];
  unresolved: UnresolvedRef[];
}

export interface FkColumnRef {
  namespace: string | null;
  table: string;
  column: string;
}

export interface ColumnUsageResponse {
  dead: FkColumnRef[];
  write_only: FkColumnRef[];
  read_only: FkColumnRef[];
  read_write: FkColumnRef[];
}

export interface StatementRef {
  file: string;
  object: string;
  proc_name: string;
  line: number;
}

export interface RitualViolation extends StatementRef {
  written_column: FkColumnRef;
}

export interface CoUpdateRitual {
  column_a: FkColumnRef;
  column_b: FkColumnRef;
  co_write_support: number;
  violations: RitualViolation[];
}

export interface CoUpdateRitualsResponse {
  rituals: CoUpdateRitual[];
}

export interface SchemaObjectRef {
  kind: "column" | "sql" | "dw_retrieve" | "unknown";
  file?: string | null;
  object?: string | null;
  proc_name?: string | null;
  line?: number | null;
  dw_name?: string | null;
  namespace?: string | null;
  table?: string | null;
  column?: string | null;
}

export interface DecompositionEvidenceLeg {
  from_object: SchemaObjectRef;
  to_object: SchemaObjectRef;
  leg_kind: string;
}

export interface DecompositionEvidencePath {
  target: SchemaObjectRef;
  direction: string;
  legs: DecompositionEvidenceLeg[];
}

export interface DecompositionCandidate {
  columns: string[];
  similarity: number;
  ritual_support: number;
  unenforced_fk_count: number;
  coslice_size: number;
  score: number | null;
  paths: DecompositionEvidencePath[];
}

export interface DecompositionCandidatesResponse {
  table: string;
  namespace: string | null;
  candidates: DecompositionCandidate[];
}

export interface DendrogramMerge {
  similarity: number;
  members: string[];
}

export interface ColumnAffinityResponse {
  table: string;
  namespace: string | null;
  columns: string[];
  co_access_matrix: number[][];
  dendrogram: DendrogramMerge[];
}

// ── Program slicing ──────────────────────────────────────────────────────────

export interface SliceStep {
  object: string;
  proc: string;
  line: number;
  var: string;
  kind: string; // 'definition' | 'use' | 'arg_pass' | 'return' | 'global_read'
  text: string;
}

export interface SliceResult {
  origin: { object: string; proc: string; line: number; var: string | null };
  direction: "backward" | "forward";
  steps: SliceStep[];
  procedures_traversed: string[];
}

export interface ExploreProcDetail {
  source_original: string | null;
  proc_type: string;
  params: string | null;
  return_type: string | null;
  modifiers: string | null;
  start_line: number | null;
  end_line: number | null;
  cyclomatic: number | null;
  sql_statements: SqlStatementRow[];
}
