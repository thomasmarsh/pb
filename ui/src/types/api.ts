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

export interface ProcedureDetailResponse extends ProcedureRow {
  file?: string;
  source_original: string | null;
  source_rendered: string;
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
  loading?: boolean;
}

export interface SearchResponse {
  objects: ObjectRow[];
  procedures: { object: string; proc_type: string; name: string; modifiers: string; start_line: number }[];
  datawindows: { dw_name: string; control_name: string; control_type: string }[];
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
  by_kind: { kind: string; count: number }[];
  top_complex: ProcedureRow[];
  top_pagerank: { object: string; pagerank: number; in_degree: number; out_degree: number }[];
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

export interface QueryResult {
  columns: string[];
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

export interface TableDetail {
  table_name:  string;
  dw_count:    number;
  ps_count:    number;
  datawindows: { dw_name: string; file: string }[];
  columns:     { dw_name: string; column_fqn: string; column_name: string }[];
  where:       { dw_name: string; idx: number; exp1: string; op: string; exp2: string; logic: string }[];
  procedures:  TableProcedureRef[];
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

export interface DwExploreDetail {
  name: string;
  controls: DwControlRow[];
  retrieve_tables: string[];
  retrieve_columns: { column_fqn: string; table_name: string; column_name: string }[];
  retrieve_where: { idx: number; exp1: string; op: string; exp2: string; logic: string }[];
  arguments: { arg_name: string; arg_type: string }[];
  error?: string;
}

export interface SqlStatementRow {
  stmt_idx: number;
  operation: string;
  raw_sql: string;
  formatted_sql: string;
  tables: string[] | null;
  columns: string[] | null;
  has_into: boolean;
  has_cursor: boolean;
  parse_ok: boolean;
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
