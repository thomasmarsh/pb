"""Query catalogue service — listing, parameter binding, and ad-hoc SQL execution."""

from __future__ import annotations

from typing import Any

import duckdb
from pb.pipeline.db import parse_sql_file
from pb.pipeline.env import env

from pb_cli.explorer.routes.dependencies import rows

_INT_TYPES = {"INT", "INTEGER", "BIGINT"}


def list_queries() -> list[dict[str, Any]]:
    queries_dir = env.build.get_queries_dir()
    if not queries_dir.is_dir():
        return []
    items = []
    for sql_file in sorted(queries_dir.glob("*.sql")):
        description, params, sql_body, _entity_types = parse_sql_file(sql_file)
        items.append(
            {
                "name": sql_file.stem,
                "description": description,
                "params": [{"name": n, "type": t, "default": d} for n, t, d in params],
                "sql": sql_body,
            }
        )
    return items


def get_query_info(name: str) -> tuple[str, list[tuple[str, str, str | None]], str, dict[str, str]]:
    sql_file = env.build.get_queries_dir() / f"{name}.sql"
    if not sql_file.exists():
        raise FileNotFoundError(f"Query not found: {name}")
    return parse_sql_file(sql_file)


def bind_params(
    params: list[tuple[str, str, str | None]],
    query_params: dict[str, str | None],
) -> tuple[dict[str, Any], list[str]]:
    bound: dict[str, Any] = {}
    missing: list[str] = []
    for pname, ptype, pdefault in params:
        raw = query_params.get(pname)
        if raw is not None:
            bound[pname] = int(raw) if ptype in _INT_TYPES else raw
        elif pdefault is not None:
            bound[pname] = int(pdefault) if ptype in _INT_TYPES else pdefault
        else:
            missing.append(pname)
    return bound, missing


def run_query(
    conn: duckdb.DuckDBPyConnection,
    name: str,
    query_params: dict[str, str | None],
) -> dict[str, Any]:
    description, params, sql, entity_types = get_query_info(name)
    bound, missing = bind_params(params, query_params)
    if missing:
        raise ValueError(f"Missing required parameters: {', '.join(missing)}")
    result = conn.execute(sql, bound)
    result_rows = rows(result)
    col_names = [d[0] for d in result.description] if result.description else []
    columns = [
        {"name": col, "entity_type": entity_types.get(col)}
        for col in col_names
    ]
    return {"columns": columns, "rows": result_rows}


def run_sql_adhoc(conn: duckdb.DuckDBPyConnection, sql: str) -> dict[str, Any]:
    upper = sql.strip().upper()
    if not (upper.startswith("SELECT") or upper.startswith("WITH")):
        raise ValueError("Only SELECT or WITH queries are allowed")
    result = conn.execute(sql)
    result_rows = rows(result)
    col_names = [d[0] for d in result.description] if result.description else []
    columns = [{"name": col, "entity_type": None} for col in col_names]
    return {"columns": columns, "rows": result_rows}
