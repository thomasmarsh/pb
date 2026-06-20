"""MySQL SQL execution endpoint for the runtime interpreter."""

from __future__ import annotations

from typing import Any, cast

import mysql.connector
from fastapi import APIRouter
from pydantic import BaseModel

router = APIRouter()

_DB_CONFIG: dict[str, Any] = {
    "host": "localhost",
    "user": "openpay",
    "password": "openpay-password",
    "database": "openpay",
}


class SqlRequest(BaseModel):
    sql: str
    params: list[Any] | None = None


class SqlResponse(BaseModel):
    rows: list[dict[str, Any]]
    columns: list[str]
    rowcount: int
    error: str | None = None


@router.post("/api/sql/execute", response_model=SqlResponse)
def execute_sql(body: SqlRequest) -> SqlResponse:
    """Execute SQL against the openpay MySQL database."""
    conn = None
    cursor = None
    try:
        conn = mysql.connector.connect(**_DB_CONFIG)
        cursor = conn.cursor(dictionary=True)
        # Trim params to the number of ? placeholders to avoid "Not all parameters
        # were used" errors when the SQL was generated without a WHERE clause.
        placeholder_count = body.sql.count("?")
        used_params = (body.params or [])[:placeholder_count]
        cursor.execute(body.sql, used_params)
        if cursor.description:
            raw = cast(list[dict[str, Any]], cursor.fetchall())
            rows: list[dict[str, Any]] = raw
            columns = [d[0] for d in cursor.description]
            return SqlResponse(rows=rows, columns=columns, rowcount=cursor.rowcount or 0)
        return SqlResponse(rows=[], columns=[], rowcount=cursor.rowcount or 0)
    except Exception as exc:
        return SqlResponse(rows=[], columns=[], rowcount=0, error=str(exc))
    finally:
        if cursor is not None:
            cursor.close()
        if conn is not None and conn.is_connected():
            conn.close()
