"""Saved SQL query catalogue and ad-hoc execution."""

from __future__ import annotations

import duckdb
from fastapi import APIRouter, Depends, HTTPException, Request

from pb_cli.explorer.routes.dependencies import get_db, rows
from pb_cli.shell.db import parse_sql_file
from pb_cli.shell.env import env

router = APIRouter()


def _query_info(name: str) -> tuple[str, list[tuple[str, str, str | None]], str, dict[str, str]]:
    sql_file = env.build.get_queries_dir() / f"{name}.sql"
    if not sql_file.exists():
        raise HTTPException(status_code=404, detail=f"Query not found: {name}")
    return parse_sql_file(sql_file)


@router.get("/api/queries")
async def list_queries():
    queries_dir = env.build.get_queries_dir()
    if not queries_dir.is_dir():
        return {"queries": []}
    items = []
    for sql_file in sorted(queries_dir.glob("*.sql")):
        description, params, sql_body, _entity_types = _query_info(sql_file.stem)
        items.append(
            {
                "name": sql_file.stem,
                "description": description,
                "params": [{"name": n, "type": t, "default": d} for n, t, d in params],
                "sql": sql_body,
            }
        )
    return {"queries": items}


@router.get("/api/queries/{name}/run")
async def run_query(name: str, request: Request, conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    description, params, sql, entity_types = _query_info(name)

    bound = {}
    missing: list[str] = []
    for pname, ptype, pdefault in params:
        raw = request.query_params.get(pname)
        if raw is not None:
            bound[pname] = int(raw) if ptype in ("INT", "INTEGER", "BIGINT") else raw
        elif pdefault is not None:
            bound[pname] = int(pdefault) if ptype in ("INT", "INTEGER", "BIGINT") else pdefault
        else:
            missing.append(pname)

    if missing:
        raise HTTPException(
            status_code=400,
            detail=f"Missing required parameters: {', '.join(missing)}",
        )

    try:
        result = conn.execute(sql, bound)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    result_rows = rows(result)
    col_names = [d[0] for d in result.description] if result.description else []
    columns = [
        {"name": col, "entity_type": entity_types.get(col)}
        for col in col_names
    ]
    return {"columns": columns, "rows": result_rows}
