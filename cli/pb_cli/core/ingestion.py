"""Pure JSON -> RowBatch transforms — no I/O dependencies."""

from __future__ import annotations

import json

from pb_cli.core.ast_walker import count_branches, walk_calls
from pb_cli.core.models import (
    CallRow,
    DwArgumentRow,
    DwControlRow,
    DwRetrieveColumnRow,
    DwRetrieveTableRow,
    DwRetrieveWhereRow,
    InheritsRow,
    ObjectRow,
    ProcedureRow,
    RowBatch,
    SqlStatementRow,
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


def ingest_file(obj: dict, rows: RowBatch, dialect: str = "oracle") -> None:
    file = obj.get("file", "")
    kind = obj.get("kind", "")
    name = _object_name(obj)
    ancestor = obj.get("meta", {}).get("ancestor")

    rows["objects"].append(ObjectRow(file, name, kind, ancestor, obj.get("source_text")))
    if ancestor:
        rows["inherits"].append(InheritsRow(name, ancestor))

    if kind == "powerscript":
        _ingest_ps(obj, file, rows, dialect)
    elif kind == "datawindow":
        _ingest_dw(obj, file, rows)


def _object_name(obj: dict) -> str:
    """Primary object name from file-level meta, falling back to filename stem."""
    if name := obj.get("meta", {}).get("object"):
        return name
    stem = obj.get("file", "").split("/")[-1]
    return stem.rsplit(".", 1)[0] if "." in stem else stem


def _ingest_ps(obj: dict, file: str, rows: RowBatch, dialect: str = "oracle") -> None:
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
            _extract_sql(file, obj_name, proc_name, row[9], dialect, rows)


def _extract_sql(
    file: str,
    obj_name: str,
    proc_name: str,
    body_json: str | None,
    dialect: str,
    rows: RowBatch,
) -> None:
    stmts = json.loads(body_json) if isinstance(body_json, str) else []
    for idx, stmt in enumerate(stmts or []):
        node = stmt.get("node", stmt)
        if node.get("tag") == "raw":
            raw = node.get("text", "")
            if _is_sql(raw):
                parsed, tables, cols, meta = parse_pb_sql(raw, dialect)
                rows["sql_statements"].append(
                    SqlStatementRow(
                        file,
                        obj_name,
                        proc_name,
                        idx,
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


def _ingest_dw(obj: dict, file: str, rows: RowBatch) -> None:
    dw_name = _object_name(obj)

    for ctrl in obj.get("controls", []):
        rows["dw_controls"].append(_ctrl_row(file, dw_name, ctrl))

    retrieve = (obj.get("table") or {}).get("retrieve")
    if not isinstance(retrieve, dict) or retrieve.get("tag") != "DwRetrieveOk":
        return

    contents = retrieve.get("contents") or {}

    for t in contents.get("tables", []):
        rows["dw_retrieve_tables"].append(DwRetrieveTableRow(file, dw_name, t))

    for col in contents.get("columns", []):
        parts = col.split(".", 1)
        rows["dw_retrieve_columns"].append(
            DwRetrieveColumnRow(
                file,
                dw_name,
                col,
                parts[0] if len(parts) == 2 else None,
                parts[1] if len(parts) == 2 else col,
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
