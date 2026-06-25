"""MySQL SQL execution endpoint for the runtime interpreter."""

from __future__ import annotations

import os
from typing import Any, cast

import mysql.connector
from fastapi import APIRouter
from pydantic import BaseModel

router = APIRouter()

def _is_mock_mode() -> bool:
    """Check mock mode at call time, not import time, to avoid test pollution."""
    return os.environ.get("PB_SQL_MOCK", "0") == "1"

_DB_CONFIG: dict[str, Any] = {
    "host": "localhost",
    "user": "openpay",
    "password": "openpay-password",
    "database": "openpay",
}

_MOCK_RESPONSES: dict[str, list[dict[str, Any]]] = {
    "misth_zpkrat": [
        {"kodkrat": "01", "kodxrisi": "0001", "desckrat": "Category 1", "isforos": True, "isasf": False, "isautoforos": False},
        {"kodkrat": "02", "kodxrisi": "0001", "desckrat": "Category 2", "isforos": False, "isasf": True, "isautoforos": False},
    ],
    "misth_ypal": [
        {"kodypal": "001", "kodxrisi": "0001", "surname": "Smith", "name": "John", "fathername": "Bob", "mitroo": "A1", "klimakio": "1", "klados": "01", "bathmos": "1", "descidikot": "Engineer"},
    ],
    "misth_zpepidom": [
        {"kodepidom": "01", "kodxrisi": "0001", "descepidom": "Allowance 1", "hasforo": True, "isasf": False, "autoforos": False, "hasasf": False},
    ],
    "misth_final": [
        {"kodfinal": "001", "kodxrisi": "0001", "descfinal": "Final 1", "datefinal": "2024-01-01", "title": "Test", "kodkat": "01", "desckat": "Cat 1", "kodperiod": "01", "descperiod": "Jan", "aa": 1},
    ],
    "misth_zpperiod": [
        {"kodperiod": "01", "kodxrisi": "0001", "descperiod": "January", "orderno": 1},
        {"kodperiod": "02", "kodxrisi": "0001", "descperiod": "February", "orderno": 2},
    ],
    "afxtranslate": [
        {"id": 655, "el": "Copyright", "uk": "Copyright"},
        {"id": 529, "el": "Period", "uk": "Period"},
    ],
    "afxinfo": [
        {"dbver": "0.1.1"},
    ],
}


class SqlRequest(BaseModel):
    sql: str
    params: list[Any] | None = None


class SqlResponse(BaseModel):
    rows: list[dict[str, Any]]
    columns: list[str]
    rowcount: int
    error: str | None = None


def _mock_execute(sql: str, params: list[Any] | None) -> SqlResponse:
    """Return mock data based on SQL table reference."""
    sql_lower = sql.lower()
    for table, rows in _MOCK_RESPONSES.items():
        if table in sql_lower:
            if params and "?" in sql:
                return SqlResponse(rows=rows, columns=list(rows[0].keys()) if rows else [], rowcount=len(rows))
            return SqlResponse(rows=rows, columns=list(rows[0].keys()) if rows else [], rowcount=len(rows))
    return SqlResponse(rows=[], columns=[], rowcount=0)


@router.post("/api/sql/execute", response_model=SqlResponse)
def execute_sql(body: SqlRequest) -> SqlResponse:
    """Execute SQL against the openpay MySQL database."""
    if _is_mock_mode():
        return _mock_execute(body.sql, body.params)
    conn = None
    cursor = None
    try:
        conn = mysql.connector.connect(**_DB_CONFIG)
        cursor = conn.cursor(dictionary=True)
        # mysql-connector-python uses %s placeholders; the frontend sends ?.
        sql = body.sql.replace("?", "%s")
        placeholder_count = sql.count("%s")
        used_params = (body.params or [])[:placeholder_count]
        cursor.execute(sql, used_params)
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
