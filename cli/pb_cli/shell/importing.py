"""Batch import of parsed file dicts into DuckDB."""

from __future__ import annotations

import json
import sys
from collections.abc import Iterable
from typing import Callable

from pb_cli.core.importing import import_file
from pb_cli.core.models import TABLES, new_row_batch
from pb_cli.shell.db import INSERT, Conn, create_schema, db_connection

_CHUNK = 5000


def run_from_jsonl_lines(lines: Iterable[str], db: str = "pb.duckdb", dialect: str = "oracle") -> None:
    rows = new_row_batch()
    for line in lines:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        import_file(obj, rows, dialect)

    with db_connection(db) as conn:
        create_schema(conn)
        for table in TABLES:
            data = rows[table]
            if data:
                conn.executemany(INSERT[table], [r._asdict() for r in data])

    total = sum(len(rows[t]) for t in TABLES)
    print(f"Indexed {total} rows into {db}", file=sys.stderr)


def import_batch(
    objects: Iterable[dict],
    conn: Conn,
    dialect: str = "oracle",
    on_progress: Callable[[int], None] | None = None,
) -> int:
    """Import an iterable of parsed file dicts into an open connection. Returns row count."""
    rows = new_row_batch()
    for obj in objects:
        import_file(obj, rows, dialect)
    total = 0
    conn.execute("BEGIN")
    try:
        for table in TABLES:
            data = rows[table]
            for i in range(0, len(data), _CHUNK):
                chunk = data[i : i + _CHUNK]
                conn.executemany(INSERT[table], [r._asdict() for r in chunk])
                total += len(chunk)
                if on_progress:
                    on_progress(len(chunk))
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise
    return total
