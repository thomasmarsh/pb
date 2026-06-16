"""DataWindow detail — controls, retrieve metadata, and source view."""

from __future__ import annotations

import os
from pathlib import Path

import duckdb
from fastapi import APIRouter, Depends, HTTPException

from pb_cli.explorer.routes.dependencies import get_db, rows
from pb_cli.explorer.services.datawindows import get_dw_detail

router = APIRouter()


@router.get("/api/dw/{name}")
async def get_datawindow(name: str, conn: duckdb.DuckDBPyConnection = Depends(get_db)):
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
        **get_dw_detail(conn, name),
    }


@router.get("/api/explore/datawindow/{name}")
async def explore_datawindow(name: str, conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    return {"name": name, **get_dw_detail(conn, name)}
