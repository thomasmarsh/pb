"""Pure row types and batch container — no I/O dependencies."""

from __future__ import annotations

from typing import NamedTuple, TypedDict


class ObjectRow(NamedTuple):
    file: str
    name: str
    kind: str
    ancestor: str | None
    source_text: str | None
    type_blocks_json: str | None
    dw_json: str | None = None


class ProcedureRow(NamedTuple):
    file: str
    object: str
    owner: str | None
    proc_type: str
    name: str
    modifiers: str | None
    params: str | None
    return_type: str | None
    start_line: int | None
    end_line: int | None
    body_json: str | None
    cyclomatic: int
    cfg_json: str | None
    cps_graph_json: str | None


class CallRow(NamedTuple):
    file: str
    object: str
    from_proc: str
    to_name: str
    call_type: str


class DwControlRow(NamedTuple):
    file: str
    dw_name: str
    control_name: str | None
    control_type: str | None
    band: str | None
    x: int | None
    y: int | None
    width: int | None
    height: int | None
    expression: str | None
    tab_seq: int | None
    source_line: int | None


class DwRetrieveTableRow(NamedTuple):
    file: str
    dw_name: str
    table_name: str


class DwRetrieveColumnRow(NamedTuple):
    file: str
    dw_name: str
    column_fqn: str
    table_name: str | None
    column_name: str


class DwRetrieveWhereRow(NamedTuple):
    file: str
    dw_name: str
    idx: int
    exp1: str | None
    op: str | None
    exp2: str | None
    logic: str | None


class DwArgumentRow(NamedTuple):
    file: str
    dw_name: str
    arg_name: str
    arg_type: str | None


class InheritsRow(NamedTuple):
    from_object: str
    to_object: str


class SqlStatementRow(NamedTuple):
    file: str
    object: str
    proc_name: str
    line: int
    operation: str | None
    raw_sql: str
    parsed_json: str | None
    tables: list[str] | None
    columns: list[str] | None
    has_into: bool
    has_cursor: bool
    parse_ok: bool


class ParseErrorRow(NamedTuple):
    file: str
    error_kind: str  # "powerscript" | "sql"
    message: str
    object: str | None
    proc_name: str | None
    line: int | None
    snippet: str | None


class LocalVarRow(NamedTuple):
    file: str
    object: str
    proc_name: str
    var_name: str
    var_type: str
    start_line: int | None


class UserTypeRow(NamedTuple):
    file: str
    type_name: str
    ancestor: str | None
    within_type: str | None


class GlobalVarRow(NamedTuple):
    file: str
    object: str
    var_name: str
    var_type: str
    modifiers: str | None
    scope: str  # 'type' | 'global'


class ResolvedTypeRow(NamedTuple):
    file: str
    object: str
    proc_name: str
    var_name: str
    raw_type: str
    resolved_kind: str  # primitive/object/user_type/any/unresolved
    resolved_target: str | None
    is_parameter: bool
    scope_line: int | None


class ResolvedCallRow(NamedTuple):
    file: str
    object: str
    from_proc: str
    to_name: str
    call_type: str
    call_line: int | None
    target_object: str | None
    target_proc: str | None
    resolution_kind: str  # static/virtual/inherited/unresolved/builtin
    confidence: str  # high/medium/low
    return_type: str | None  # PB API return type for builtin calls; None otherwise


class RowBatch(TypedDict):
    objects: list[ObjectRow]
    procedures: list[ProcedureRow]
    calls: list[CallRow]
    dw_controls: list[DwControlRow]
    dw_retrieve_tables: list[DwRetrieveTableRow]
    dw_retrieve_columns: list[DwRetrieveColumnRow]
    dw_retrieve_where: list[DwRetrieveWhereRow]
    dw_arguments: list[DwArgumentRow]
    inherits: list[InheritsRow]
    sql_statements: list[SqlStatementRow]
    parse_errors: list[ParseErrorRow]
    local_variables: list[LocalVarRow]
    user_types: list[UserTypeRow]
    global_vars: list[GlobalVarRow]


def new_row_batch() -> RowBatch:
    return RowBatch(
        objects=[],
        procedures=[],
        calls=[],
        dw_controls=[],
        dw_retrieve_tables=[],
        dw_retrieve_columns=[],
        dw_retrieve_where=[],
        dw_arguments=[],
        inherits=[],
        sql_statements=[],
        parse_errors=[],
        local_variables=[],
        user_types=[],
        global_vars=[],
    )


TABLES = [
    "objects",
    "procedures",
    "calls",
    "dw_controls",
    "dw_retrieve_tables",
    "dw_retrieve_columns",
    "dw_retrieve_where",
    "dw_arguments",
    "inherits",
    "sql_statements",
    "parse_errors",
    "local_variables",
    "user_types",
    "global_vars",
]
