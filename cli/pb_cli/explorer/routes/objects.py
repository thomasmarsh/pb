"""Object listing, detail, source, and the library/object explore tree."""

from __future__ import annotations

import os
from typing import Any

from fastapi import APIRouter, HTTPException, Query, Request

from pb_cli.explorer.routes.dependencies import get_conn, rows

router = APIRouter()


@router.get("/api/objects")
async def list_objects(
    request: Request,
    q: str = Query("", description="Search term"),
    kind: str = Query("", description="Filter by kind"),
    sort: str = Query("name", description="Sort column"),
    order: str = Query("asc", description="Sort direction"),
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
):
    conn = get_conn(request)
    try:
        conditions = []
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
    finally:
        conn.close()


@router.get("/api/objects/{name}")
async def get_object(name: str, request: Request):
    conn = get_conn(request)
    try:
        obj_rows = rows(conn.execute("SELECT name, kind, file, ancestor FROM objects WHERE name = ?", [name]))
        if not obj_rows:
            raise HTTPException(status_code=404, detail=f"Object not found: {name}")
        obj = obj_rows[0]

        metrics = rows(conn.execute("SELECT * FROM object_metrics WHERE object = ?", [name]))
        obj["metrics"] = metrics[0] if metrics else None

        procs = rows(
            conn.execute(
                "SELECT object, proc_type, name, modifiers, params, return_type, "
                "start_line, end_line, cyclomatic "
                "FROM procedures WHERE object = ? ORDER BY proc_type, name",
                [name],
            )
        )
        obj["procedures"] = procs

        ancestors = rows(conn.execute("SELECT to_object AS parent FROM inherits WHERE from_object = ?", [name]))
        obj["ancestors"] = [a["parent"] for a in ancestors]

        descendants = rows(conn.execute("SELECT from_object AS child FROM inherits WHERE to_object = ?", [name]))
        obj["descendants"] = [d["child"] for d in descendants]

        callers = rows(conn.execute("SELECT DISTINCT object AS caller FROM calls WHERE to_name = ?", [name]))
        obj["callers"] = [c["caller"] for c in callers]

        callees = rows(conn.execute("SELECT DISTINCT to_name AS callee FROM calls WHERE object = ?", [name]))
        obj["callees"] = [c["callee"] for c in callees]

        return obj
    finally:
        conn.close()


@router.get("/api/objects/{name}/source")
async def get_object_source(name: str, request: Request):
    conn = get_conn(request)
    try:
        obj_rows = rows(conn.execute("SELECT name, kind, file, source_text FROM objects WHERE name = ?", [name]))
        if not obj_rows:
            raise HTTPException(status_code=404, detail=f"Object not found: {name}")

        file_path = obj_rows[0]["file"]
        lines = []
        if file_path and os.path.exists(file_path):
            try:
                with open(file_path, "r", errors="replace") as f:
                    lines = f.read().splitlines()
            except OSError:
                pass
        if not lines and obj_rows[0].get("source_text"):
            lines = obj_rows[0]["source_text"].splitlines()

        procs = rows(
            conn.execute(
                "SELECT name, proc_type, modifiers, params, return_type, "
                "start_line, end_line, cyclomatic "
                "FROM procedures WHERE object = ? "
                "AND start_line IS NOT NULL AND end_line IS NOT NULL "
                "ORDER BY start_line",
                [name],
            )
        )

        known_objects = rows(conn.execute("SELECT name, kind FROM objects WHERE name != ? ORDER BY name", [name]))

        known_procs = rows(
            conn.execute(
                "SELECT DISTINCT p.name, p.object, p.proc_type "
                "FROM procedures p "
                "JOIN calls c ON c.to_name = p.name "
                "WHERE c.object = ? "
                "UNION "
                "SELECT DISTINCT p.name, p.object, p.proc_type "
                "FROM procedures p "
                "WHERE p.object = ? AND p.proc_type IN ('function', 'subroutine') "
                "ORDER BY p.name",
                [name, name],
            )
        )

        return {
            "file": file_path,
            "lines": lines,
            "source_available": bool(lines),
            "procedures": procs,
            "knownObjects": known_objects,
            "knownProcs": known_procs,
        }
    finally:
        conn.close()


def _pbl_name(file_path: str) -> str:
    """Extract .pbl library name from an extracted file path."""
    parts = file_path.replace("\\", "/").split("/")
    for part in parts:
        if part.lower().endswith(".pbl"):
            return part
    if len(parts) >= 2:
        return parts[-2]
    return "(unknown)"


@router.get("/api/explore/tree")
async def explore_tree(request: Request):
    conn = get_conn(request)
    try:
        obj_rows = rows(conn.execute("SELECT name, kind, file FROM objects ORDER BY kind, name"))
        proc_rows = rows(
            conn.execute(
                "SELECT object, proc_type, name, modifiers, params, return_type, "
                "start_line, end_line, cyclomatic "
                "FROM procedures ORDER BY object, proc_type, name"
            )
        )
        procs_by_obj: dict[str, list[dict[str, Any]]] = {}
        for p in proc_rows:
            procs_by_obj.setdefault(p["object"], []).append(p)

        libraries: dict[str, list[dict[str, Any]]] = {}
        for obj in obj_rows:
            fpath = obj.get("file", "")
            lib = _pbl_name(fpath)
            obj_entry = {
                "name": obj["name"],
                "kind": obj["kind"],
                "file": fpath,
                "procedures": procs_by_obj.get(obj["name"], []),
            }
            libraries.setdefault(lib, []).append(obj_entry)

        result = [{"name": lib, "objects": objs} for lib, objs in sorted(libraries.items())]
        return {"libraries": result}
    finally:
        conn.close()
