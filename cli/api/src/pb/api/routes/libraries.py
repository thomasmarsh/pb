"""Library detail endpoint."""

from __future__ import annotations

import duckdb
from fastapi import APIRouter, Depends, HTTPException
from pb.api.routes.dependencies import get_db
from pb.api.services.libraries import get_library_detail

router = APIRouter()


@router.get("/api/libraries/{name}")
async def get_library(name: str, conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    result = get_library_detail(conn, name)
    if result is None:
        raise HTTPException(status_code=404, detail=f"Library not found: {name}")
    return result
