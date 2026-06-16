"""DataWindow detail — controls, retrieve metadata, and source view."""

from __future__ import annotations

import os
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request

from pb_cli.explorer.routes.dependencies import get_conn, rows

router = APIRouter()


def _dw_detail(conn, name: str) -> dict:
    controls = rows(
        conn.execute(
            "SELECT control_name, control_type, band, x, y, width, height, "
            "expression, tab_seq, source_line "
            "FROM dw_controls WHERE dw_name = ? ORDER BY band, y, x",
            [name],
        )
    )
    tables = rows(
        conn.execute("SELECT table_name FROM dw_retrieve_tables WHERE dw_name = ? ORDER BY table_name", [name])
    )
    columns = rows(
        conn.execute(
            "SELECT column_fqn, table_name, column_name "
            "FROM dw_retrieve_columns WHERE dw_name = ? ORDER BY table_name, column_name",
            [name],
        )
    )
    where = rows(
        conn.execute("SELECT idx, exp1, op, exp2, logic FROM dw_retrieve_where WHERE dw_name = ? ORDER BY idx", [name])
    )
    arguments = rows(
        conn.execute("SELECT arg_name, arg_type FROM dw_arguments WHERE dw_name = ? ORDER BY arg_name", [name])
    )
    return {
        "controls": controls,
        "retrieve_tables": [t["table_name"] for t in tables],
        "retrieve_columns": columns,
        "retrieve_where": where,
        "arguments": arguments,
    }


@router.get("/api/dw/{name}")
async def get_datawindow(name: str, request: Request):
    conn = get_conn(request)
    try:
        file_rows = rows(conn.execute("SELECT DISTINCT file FROM dw_controls WHERE dw_name = ?", [name]))
        if not file_rows:
            raise HTTPException(status_code=404, detail=f"DataWindow not found: {name}")

        source_file = file_rows[0]["file"]
        source_original = None
        if os.path.exists(source_file):
            try:
                source_original = Path(source_file).read_text(errors="replace")
            except OSError:
                pass

        return {
            "name": name,
            "file": source_file,
            "source": source_original,
            **_dw_detail(conn, name),
        }
    finally:
        conn.close()


@router.get("/api/explore/datawindow/{name}")
async def explore_datawindow(name: str, request: Request):
    conn = get_conn(request)
    try:
        return {"name": name, **_dw_detail(conn, name)}
    finally:
        conn.close()
