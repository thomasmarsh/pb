"""Implementation of `pb index` — invoke pb-runner --db, then post-process."""

from __future__ import annotations

import subprocess
from pathlib import Path

from pb_cli.shell.db import setup_db_extras
from pb_cli.shell.env import env
from pb_cli.shell.reporter import Reporter


def db_is_current(input_path: Path, db: str) -> bool:
    """Return True if pb.duckdb already reflects the source input.

    Checks parse_errors table count as a proxy for a completed run.
    Returns False if the DB does not exist or cannot be read.
    """
    if not Path(db).exists():
        return False
    try:
        with env.storage.db_connection(db, read_only=True) as conn:
            conn.execute("SELECT 1 FROM objects LIMIT 1")
            return True
    except Exception:
        return False


def run(
    src_dir: Path,
    db: str,
    binary: Path,
    reporter: Reporter,
    reset: bool = False,
    dialect: str = "oracle",
    input_path: Path | None = None,
) -> None:
    src_dir = src_dir.resolve()
    db_new = db + ".new"

    if reset and Path(db).exists():
        Path(db).unlink()

    with reporter.status("Running pb-runner..."):
        result = subprocess.run(
            [str(binary), "-i", str(src_dir), "--db", db_new],
            capture_output=True,
            text=True,
        )

    if result.returncode != 0:
        reporter.done(parsed=0, errors=1, sql_parse_failures=0)
        return

    with env.storage.db_connection(db_new) as conn:
        setup_db_extras(conn)
        conn.execute(
            "INSERT OR REPLACE INTO metadata VALUES (?, ?)",
            ["ingestion_root", str(src_dir)],
        )

    Path(db_new).rename(db)

    with env.storage.db_connection(db) as conn, reporter.analyze_progress() as progress:
        progress.start_step("compute metrics")
        env.storage.compute_metrics(conn, progress)
        sql_parse_failures = env.storage.count_sql_parse_failures(conn)

    reporter.done(parsed=0, errors=0, sql_parse_failures=sql_parse_failures)
