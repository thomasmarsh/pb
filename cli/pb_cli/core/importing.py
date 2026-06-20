"""Pure JSON -> RowBatch transforms — no I/O dependencies."""

from __future__ import annotations

import json

from pb_cli.core.ast_walker import (
    count_branches,
    walk_bsraw_located,
    walk_calls,
    walk_excall_arg_calls,
    walk_local_vars,
)
from pb_cli.core.models import (
    CallRow,
    DwArgumentRow,
    DwControlRow,
    DwRetrieveColumnRow,
    DwRetrieveTableRow,
    DwRetrieveWhereRow,
    GlobalVarRow,
    InheritsRow,
    LocalVarRow,
    ObjectRow,
    ParseErrorRow,
    ProcedureRow,
    RowBatch,
    SqlStatementRow,
    UserTypeRow,
)
from pb_cli.core.sql import parse_pb_sql

_SQL_KEYWORDS = {
    "SELECT",
    "INSERT",
    "UPDATE",
    "DELETE",
    "DECLARE",
    "OPEN",
    "FETCH",
    "CLOSE",
    "COMMIT",
    "ROLLBACK",
    "EXECUTE",
    "CONNECT",
    "DISCONNECT",
}


def _is_sql(text: str) -> bool:
    first = text.strip().split()[0].upper() if text.strip() else ""
    return first in _SQL_KEYWORDS


def import_file(obj: dict, rows: RowBatch, dialect: str = "oracle") -> None:
    file = obj.get("file", "")
    kind = obj.get("kind", "")
    name = _object_name(obj)
    ancestor = obj.get("meta", {}).get("ancestor")

    rows["objects"].append(ObjectRow(file, name, kind, ancestor, obj.get("source_text")))
    if ancestor:
        rows["inherits"].append(InheritsRow(name, ancestor))

    if kind == "powerscript":
        _import_ps(obj, file, rows, dialect)
        _import_user_types(obj, file, rows)
        _import_variables(obj, file, rows)
    elif kind == "datawindow":
        _import_dw(obj, file, rows)


def _object_name(obj: dict) -> str:
    """Primary object name from file-level meta, falling back to filename stem."""
    if name := obj.get("meta", {}).get("object"):
        return name
    stem = obj.get("file", "").split("/")[-1]
    return stem.rsplit(".", 1)[0] if "." in stem else stem


def _import_ps(obj: dict, file: str, rows: RowBatch, dialect: str = "oracle") -> None:
    obj_name = obj.get("meta", {}).get("object", "")
    for proc_type, key in [
        ("function", "functions"),
        ("subroutine", "subroutines"),
        ("event", "events"),
        ("on", "onBlocks"),
    ]:
        for block in obj.get(key, []):
            body = block.get("body") or []
            row = _proc_row(file, proc_type, block, body)
            rows["procedures"].append(row)
            proc_name = row[3]
            for callee, call_type in walk_calls(body):
                if callee:
                    rows["calls"].append(CallRow(file, obj_name, proc_name, callee, call_type))
            for callee in walk_excall_arg_calls(body):
                if callee:
                    rows["calls"].append(CallRow(file, obj_name, proc_name, callee, "ExCallArg"))
            _extract_sql(file, obj_name, proc_name, row[9], dialect, rows)
            for var_name, var_type in walk_local_vars(body):
                rows["local_variables"].append(LocalVarRow(
                    file=file, object=obj_name, proc_name=proc_name,
                    var_name=var_name, var_type=var_type, start_line=None
                ))


def _extract_sql(
    file: str,
    obj_name: str,
    proc_name: str,
    body_json: str | None,
    dialect: str,
    rows: RowBatch,
) -> None:
    stmts = json.loads(body_json) if isinstance(body_json, str) else []
    for raw, line in walk_bsraw_located(stmts):
        if _is_sql(raw):
            parsed, tables, cols, meta = parse_pb_sql(raw, dialect)
            line_no = line if line is not None else -1
            rows["sql_statements"].append(
                SqlStatementRow(
                    file,
                    obj_name,
                    proc_name,
                    line_no,
                    meta["operation"],
                    raw,
                    json.dumps(parsed) if parsed is not None else None,
                    tables,
                    cols,
                    meta["has_into"],
                    meta["has_cursor"],
                    parsed is not None,
                )
            )
            if "error" in meta:
                rows["parse_errors"].append(
                    ParseErrorRow(file, "sql", meta["error"], obj_name, proc_name, line, raw)
                )


def _proc_row(file: str, proc_type: str, block: dict, body: list) -> ProcedureRow:
    meta = block.get("meta") or {}
    if proc_type == "on":
        name, modifiers, params, return_type = block.get("event", ""), None, None, None
    else:
        sig = block.get("sig") or {}
        name = sig.get("name", "")
        mods = sig.get("modifiers") or []
        modifiers = " ".join(mods) if mods else None
        params = sig.get("params") or sig.get("rawSig")
        return_type = sig.get("returnType")
    return ProcedureRow(
        file,
        meta.get("object", ""),
        proc_type,
        name,
        modifiers,
        params,
        return_type,
        meta.get("startLine"),
        meta.get("endLine"),
        json.dumps(body),
        block.get("source_rendered", ""),
        count_branches(body) + 1,
    )


def _import_dw(obj: dict, file: str, rows: RowBatch) -> None:
    dw_name = _object_name(obj)

    for ctrl in obj.get("controls", []):
        rows["dw_controls"].append(_ctrl_row(file, dw_name, ctrl))
        ctrl_name = ctrl.get("name") or ""
        for ast_key in ("parsedExpression", "parsedFormat"):
            ast_node = ctrl.get(ast_key)
            if isinstance(ast_node, dict):
                for callee, call_type in walk_calls(ast_node):
                    if callee:
                        rows["calls"].append(CallRow(file, dw_name, ctrl_name, callee, call_type))

    retrieve = (obj.get("table") or {}).get("retrieve")
    if not isinstance(retrieve, dict) or retrieve.get("tag") != "DwRetrieveOk":
        return

    contents = retrieve.get("contents") or {}

    for t in contents.get("tables", []):
        rows["dw_retrieve_tables"].append(DwRetrieveTableRow(file, dw_name, t.lower()))

    for col in contents.get("columns", []):
        parts = col.split(".", 1)
        col_fqn = col.lower() if len(parts) == 2 else col
        col_name = parts[1].lower() if len(parts) == 2 else col.lower()
        rows["dw_retrieve_columns"].append(
            DwRetrieveColumnRow(
                file,
                dw_name,
                col_fqn,
                parts[0].lower() if len(parts) == 2 else None,
                col_name,
            )
        )

    for i, w in enumerate(contents.get("where", [])):
        rows["dw_retrieve_where"].append(
            DwRetrieveWhereRow(
                file,
                dw_name,
                i,
                w.get("exp1"),
                w.get("op"),
                w.get("exp2"),
                w.get("logic"),
            )
        )

    for a in contents.get("arguments", []):
        rows["dw_arguments"].append(DwArgumentRow(file, dw_name, a.get("name"), a.get("type")))


def _ctrl_row(file: str, dw_name: str, ctrl: dict) -> DwControlRow:
    band = ctrl.get("band")
    if isinstance(band, dict):
        band = band.get("tag")
    meta = ctrl.get("meta") or {}
    return DwControlRow(
        file,
        dw_name,
        ctrl.get("name"),
        ctrl.get("type"),
        band,
        ctrl.get("x"),
        ctrl.get("y"),
        ctrl.get("width"),
        ctrl.get("height"),
        ctrl.get("expression"),
        ctrl.get("tab_seq"),
        meta.get("sourceLine"),
    )


def _import_user_types(obj: dict, file: str, rows: RowBatch) -> None:
    """Extract user type declarations from type blocks and forward blocks."""
    for tb in obj.get("typeBlocks", []):
        decl = tb.get("decl", {})
        rows["user_types"].append(UserTypeRow(
            file=file,
            type_name=decl.get("name", ""),
            ancestor=decl.get("ancestor"),
            within_type=decl.get("within"),
        ))

    fwd = obj.get("forward") or {}
    for td in fwd.get("types", []):
        rows["user_types"].append(UserTypeRow(
            file=file,
            type_name=td.get("name", ""),
            ancestor=td.get("ancestor"),
            within_type=None,
        ))


def _import_variables(obj: dict, file: str, rows: RowBatch) -> None:
    """Extract instance and global variable declarations."""
    obj_name = obj.get("meta", {}).get("object", "")

    variables = obj.get("variables") or {}
    scope = variables.get("scope", "")
    for decl in variables.get("decls", []):
        mods = decl.get("modifiers") or []
        rows["global_vars"].append(GlobalVarRow(
            file=file,
            object=obj_name,
            var_name=decl.get("name", ""),
            var_type=decl.get("type", ""),
            modifiers=" ".join(mods) if mods else None,
            scope=scope,
        ))

    for inst in obj.get("globalInstances", []):
        rows["global_vars"].append(GlobalVarRow(
            file=file,
            object=obj_name,
            var_name=inst.get("name", ""),
            var_type=inst.get("type", ""),
            modifiers=None,
            scope="instance",
        ))
