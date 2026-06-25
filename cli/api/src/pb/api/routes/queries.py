"""Saved SQL query catalogue and ad-hoc execution."""

from __future__ import annotations

import duckdb
from fastapi import APIRouter, Depends, HTTPException, Request
from pb.api.routes.dependencies import get_db
from pb.api.services.queries import list_queries, run_query, run_sql_adhoc
from pydantic import BaseModel

router = APIRouter()


@router.get("/api/queries")
async def list_queries_endpoint():
    return {"queries": list_queries()}


@router.get("/api/queries/{name}/run")
async def run_query_endpoint(name: str, request: Request, conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    try:
        return run_query(conn, name, dict(request.query_params))
    except FileNotFoundError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


class RunSqlBody(BaseModel):
    sql: str


@router.post("/api/queries/run-sql")
async def run_sql_adhoc_endpoint(body: RunSqlBody, conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    try:
        return run_sql_adhoc(conn, body.sql.strip())
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
