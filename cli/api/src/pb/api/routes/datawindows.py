"""DataWindow detail — controls, retrieve metadata, and source view."""

from __future__ import annotations

import duckdb
from fastapi import APIRouter, Depends, HTTPException
from pb.api.routes.dependencies import get_db
from pb.api.services.datawindows import get_datawindow_detail

router = APIRouter()


@router.get("/api/datawindow/{name}")
async def get_datawindow(name: str, conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    result = get_datawindow_detail(conn, name)
    if result is None:
        raise HTTPException(status_code=404, detail=f"DataWindow not found: {name}")
    return result
