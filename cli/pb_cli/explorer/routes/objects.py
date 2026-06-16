"""Object listing, detail, source, and the library/object explore tree."""

from __future__ import annotations

from typing import Any

import duckdb
from fastapi import APIRouter, Depends, HTTPException, Query

from pb_cli.explorer.routes.dependencies import get_db, rows
from pb_cli.explorer.services.objects import get_explore_tree, get_object_detail, get_object_source

router = APIRouter()


@router.get("/api/objects")
async def list_objects(
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
    q: str = Query("", description="Search term"),
    kind: str = Query("", description="Filter by kind"),
    sort: str = Query("name", description="Sort column"),
    order: str = Query("asc", description="Sort direction"),
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
):
    conditions: list[str] = []
    params: list[Any] = []
    if q:
        conditions.append("(o.name ILIKE ? OR o.file ILIKE ?)")
        params += [f"%{q}%", f"%{q}%"]
    if kind:
        conditions.append("o.kind = ?")
        params.append(kind)
    where = "WHERE " + " AND ".join(conditions) if conditions else ""

    safe_sorts = {"name", "kind", "file"}
    sort_col = sort if sort in safe_sorts else "name"
    sort_dir = "DESC" if order.lower() == "desc" else "ASC"

    count_row = conn.execute(f"SELECT count(*) FROM objects o {where}", params).fetchone()
    total = count_row[0] if count_row else 0

    items = rows(
        conn.execute(
            f"SELECT o.name, o.kind, o.file, o.ancestor "
            f"FROM objects o {where} "
            f"ORDER BY o.{sort_col} {sort_dir} "
            f"LIMIT ? OFFSET ?",
            params + [limit, offset],
        )
    )
    return {"total": total, "offset": offset, "limit": limit, "items": items}


@router.get("/api/objects/{name}")
async def get_object(name: str, conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    obj = get_object_detail(conn, name)
    if obj is None:
        raise HTTPException(status_code=404, detail=f"Object not found: {name}")
    return obj


@router.get("/api/objects/{name}/source")
async def get_object_source_route(name: str, conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    result = get_object_source(conn, name)
    if result is None:
        raise HTTPException(status_code=404, detail=f"Object not found: {name}")
    return result


@router.get("/api/explore/tree")
async def explore_tree(conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    return get_explore_tree(conn)
