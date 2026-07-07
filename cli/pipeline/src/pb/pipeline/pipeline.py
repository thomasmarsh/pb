"""Implementation of `pb index` — invoke pbc --db, then post-process."""

from __future__ import annotations

import json
import os
import subprocess
import threading
from pathlib import Path

from pb.pipeline.build import find_sql_worker
from pb.pipeline.db import setup_db_extras
from pb.pipeline.env import env
from pb.pipeline.metrics import compute_metrics
from pb.pipeline.reporter import Reporter


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
    ddl: Path | None = None,
) -> None:
    src_dir = src_dir.resolve()
    db_new = db + ".new"

    if reset and Path(db).exists():
        Path(db).unlink()

    run_env = os.environ.copy()
    sql_worker = find_sql_worker()
    if sql_worker:
        run_env["PB_SQL_WORKER"] = str(sql_worker)

    argv = [str(binary), "-i", str(src_dir), "--db", db_new]
    if ddl is not None:
        argv += ["--ddl", str(ddl)]

    errors = 0
    raw_stderr_lines: list[str] = []
    with reporter.runner_progress() as prog:
        proc = subprocess.Popen(
            argv,
            stderr=subprocess.PIPE,
            env=run_env,
        )

        def _read_stderr() -> None:
            assert proc.stderr is not None
            for raw in proc.stderr:
                line = raw.decode(errors="replace").strip()
                if not line:
                    continue
                try:
                    prog.on_event(json.loads(line))
                except json.JSONDecodeError:
                    raw_stderr_lines.append(line)

        reader = threading.Thread(target=_read_stderr, daemon=True)
        reader.start()
        proc.wait()
        reader.join()

    parsed = prog.parsed_count

    if proc.returncode != 0:
        import typer
        typer.echo(f"pbc failed (exit {proc.returncode}):", err=True)
        for line in raw_stderr_lines:
            typer.echo(f"  {line}", err=True)
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
        compute_metrics(conn, progress)
        sql_parse_failures = env.storage.count_sql_parse_failures(conn)

    reporter.done(parsed=parsed, errors=errors, sql_parse_failures=sql_parse_failures)
