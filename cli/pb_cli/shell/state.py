"""Incremental file-state persistence (detect changed files)."""

from __future__ import annotations

from datetime import datetime, timezone

from pb_cli.core.models import TABLES
from pb_cli.shell.db import Conn

FILE_STATE_SQL = """
CREATE TABLE IF NOT EXISTS file_state (
    file      TEXT PRIMARY KEY,
    sha256    TEXT NOT NULL,
    parsed_at TEXT NOT NULL
);
"""


def create_state_table(conn: Conn) -> None:
    conn.execute(FILE_STATE_SQL)


def load_file_state(conn: Conn) -> dict[str, str]:
    """Return {file: sha256} from file_state. Returns empty dict if table is missing."""
    try:
        rows = conn.execute("SELECT file, sha256 FROM file_state").fetchall()
        return {r[0]: r[1] for r in rows}
    except Exception:
        return {}


def delete_file_rows(conn: Conn, file_path: str) -> None:
    """Remove all DB rows for a source file (data tables + inherits + file_state)."""
    objs = conn.execute("SELECT name FROM objects WHERE file = ?", [file_path]).fetchall()
    obj_names = [r[0] for r in objs]

    for table in TABLES:
        if table == "inherits":
            continue
        conn.execute(f"DELETE FROM {table} WHERE file = ?", [file_path])

    if obj_names:
        placeholders = ",".join("?" * len(obj_names))
        conn.execute(f"DELETE FROM inherits WHERE from_object IN ({placeholders})", obj_names)

    conn.execute("DELETE FROM file_state WHERE file = ?", [file_path])


def save_file_state(conn: Conn, file_states: dict[str, str]) -> None:
    """Insert or replace file state entries."""
    now = datetime.now(timezone.utc).isoformat()
    for file_path, sha in file_states.items():
        conn.execute("DELETE FROM file_state WHERE file = ?", [file_path])
    rows = [(f, h, now) for f, h in file_states.items()]
    if rows:
        conn.executemany("INSERT INTO file_state VALUES (?, ?, ?)", rows)
