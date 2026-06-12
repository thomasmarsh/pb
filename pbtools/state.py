"""Incremental state: SHA256 hashing, file_state table, diff logic, subset tmpdir."""
import hashlib
import os
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import NamedTuple

from pbtools.build import walk_sr_files
from pbtools.common import TABLES


FILE_STATE_SQL = """
CREATE TABLE IF NOT EXISTS file_state (
    file      TEXT PRIMARY KEY,
    sha256    TEXT NOT NULL,
    parsed_at TEXT NOT NULL
);
"""


class FileDiff(NamedTuple):
    new:       list[str]
    changed:   list[str]
    deleted:   list[str]
    unchanged: list[str]


def create_state_table(conn) -> None:
    conn.execute(FILE_STATE_SQL)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hash_source_dir(src_dir: Path) -> dict[str, str]:
    """SHA256-hash every .sr* file under src_dir. Keys are absolute path strings."""
    return {str(f): _sha256(f) for f in walk_sr_files(src_dir)}


def load_file_state(conn) -> dict[str, str]:
    """Return {file: sha256} from file_state. Returns empty dict if table is missing."""
    try:
        rows = conn.execute("SELECT file, sha256 FROM file_state").fetchall()
        return {r[0]: r[1] for r in rows}
    except Exception:
        return {}


def diff_state(current: dict[str, str], stored: dict[str, str]) -> FileDiff:
    new       = [f for f in current if f not in stored]
    changed   = [f for f in current if f in stored and current[f] != stored[f]]
    deleted   = [f for f in stored  if f not in current]
    unchanged = [f for f in current if f in stored and current[f] == stored[f]]
    return FileDiff(new=new, changed=changed, deleted=deleted, unchanged=unchanged)


def delete_file_rows(conn, file_path: str) -> None:
    """Remove all DB rows for a source file (data tables + inherits + file_state)."""
    # Fetch object names before deleting from objects table
    objs = conn.execute(
        "SELECT name FROM objects WHERE file = ?", [file_path]
    ).fetchall()
    obj_names = [r[0] for r in objs]

    for table in TABLES:
        if table == 'inherits':
            continue
        conn.execute(f"DELETE FROM {table} WHERE file = ?", [file_path])

    if obj_names:
        placeholders = ','.join('?' * len(obj_names))
        conn.execute(
            f"DELETE FROM inherits WHERE from_object IN ({placeholders})", obj_names
        )

    conn.execute("DELETE FROM file_state WHERE file = ?", [file_path])


def save_file_state(conn, file_states: dict[str, str]) -> None:
    """Insert or replace file state entries."""
    now = datetime.now(timezone.utc).isoformat()
    for file_path, sha in file_states.items():
        conn.execute("DELETE FROM file_state WHERE file = ?", [file_path])
    rows = [(f, h, now) for f, h in file_states.items()]
    if rows:
        conn.executemany("INSERT INTO file_state VALUES (?, ?, ?)", rows)


def build_subset_tmpdir(src_dir: Path, files: list[str]) -> Path:
    """
    Copy a subset of source files into a fresh tmpdir preserving relative paths.
    Uses hard links where possible, falls back to shutil.copy2 for cross-volume.
    Caller must clean up the returned directory (shutil.rmtree).
    """
    tmpdir = Path(tempfile.mkdtemp())
    for abs_path in files:
        src = Path(abs_path)
        try:
            rel = src.relative_to(src_dir)
        except ValueError:
            rel = Path(src.name)
        dst = tmpdir / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.link(src, dst)
        except OSError:
            shutil.copy2(src, dst)
    return tmpdir
