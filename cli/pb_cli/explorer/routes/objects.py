"""Object listing, detail, source, and the library/object explore tree."""

from __future__ import annotations

import duckdb
from fastapi import APIRouter, Depends, HTTPException, Query

from pb_cli.explorer.routes.dependencies import get_db
from pb_cli.explorer.services.objects import get_explore_tree, get_object_detail, get_object_source, list_objects

router = APIRouter()


@router.get("/api/objects")
async def list_objects_endpoint(
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
    q: str = Query("", description="Search term"),
    kind: str = Query("", description="Filter by kind"),
    sort: str = Query("name", description="Sort column"),
    order: str = Query("asc", description="Sort direction"),
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
):
    return list_objects(conn, q=q, kind=kind, sort=sort, order=order, limit=limit, offset=offset)


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
