"""DataWindow detail — controls, retrieve metadata, and source view."""

from __future__ import annotations

from pathlib import Path

import duckdb
from fastapi import APIRouter, Depends, HTTPException

from pb_cli.explorer.routes.dependencies import get_db, rows
from pb_cli.explorer.services.datawindows import get_dw_detail
from pb_cli.explorer.services.objects import _get_root

router = APIRouter()


@router.get("/api/dw/{name}")
async def get_datawindow(name: str, conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    file_rows = rows(conn.execute("SELECT DISTINCT file FROM dw_controls WHERE dw_name = ?", [name]))
    if not file_rows:
        raise HTTPException(status_code=404, detail=f"DataWindow not found: {name}")

    source_file = file_rows[0]["file"]

    source_original = None
    source_rows = rows(conn.execute(
        "SELECT source_text FROM objects WHERE name = ?", [name]
    ))
    if source_rows and source_rows[0].get("source_text"):
        source_original = source_rows[0]["source_text"]

    if not source_original:
        root = _get_root(conn)
        disk_path = (root / source_file) if root else Path(source_file)
        if disk_path.exists():
            try:
                source_original = disk_path.read_text(errors="replace")
            except OSError:
                pass

    return {
        "name": name,
        "file": source_file,
        "source": source_original,
        **get_dw_detail(conn, name),
    }


@router.get("/api/explore/datawindow/{name}")
async def explore_datawindow(name: str, conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    return {"name": name, **get_dw_detail(conn, name)}
