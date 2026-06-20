// API types derived from DuckDB schema (cli/pb_cli/common.py) and api.py routes.

import type { BodyStmt, Located } from "./ast.generated.js";

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
  body_json?: string;
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
  modifiers: string | null;
  params: string | null;
  return_type: string | null;
  start_line: number | null;
  end_line: number | null;
  cyclomatic: number | null;
}

export interface ObjectSourceResponse {
  file: string;
  lines: string[];
  procedures: ProcedureInfo[];
  knownObjects: { name: string; kind: string }[];
  knownProcs: { name: string; object: string; proc_type: string }[];
  loading?: boolean;
}

export interface ProcCallerInfo {
  object: string;
  proc: string;
}

export interface ProcedureDetailResponse extends ProcedureRow {
  file?: string;
  source_original: string | null;
  source_rendered: string;
  callers?: ProcCallerInfo[];
  callees?: string[];
  sql_statements?: SqlStatementRow[];
  activeTab?: string;
  loading?: boolean;
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

export interface TableSummary {
  table_name: string;
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
  ast: Located<BodyStmt>[] | null;
  source_rendered: string;
  proc_type: string;
  params: string | null;
  return_type: string | null;
  modifiers: string | null;
  start_line: number | null;
  end_line: number | null;
  cyclomatic: number | null;
  sql_statements: SqlStatementRow[];
}
