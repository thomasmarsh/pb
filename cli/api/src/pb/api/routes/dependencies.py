"""Shared helpers for all route modules."""

from __future__ import annotations

import os
from collections.abc import Generator
from typing import Any

import duckdb
from fastapi import HTTPException, Request

_WRITE_OPS = {"INSERT", "UPDATE", "DELETE"}


def get_conn(request: Request) -> duckdb.DuckDBPyConnection:
    db_path: str = request.app.state.db_path
    if not os.path.exists(db_path):
        raise HTTPException(status_code=503, detail=f"Database not found: {db_path}")
    return duckdb.connect(db_path, read_only=True)


def get_db(request: Request) -> Generator[duckdb.DuckDBPyConnection, None, None]:
    db_path: str = request.app.state.db_path
    if not os.path.exists(db_path):
        raise HTTPException(status_code=503, detail=f"Database not found: {db_path}")
    conn = duckdb.connect(db_path, read_only=True)
    try:
        yield conn
    finally:
        conn.close()


def rows(cursor: duckdb.DuckDBPyConnection) -> list[dict[str, Any]]:
    cols = [d[0] for d in cursor.description]
    return [dict(zip(cols, row)) for row in cursor.fetchall()]
