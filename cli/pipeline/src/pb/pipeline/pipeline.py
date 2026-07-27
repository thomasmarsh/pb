"""Implementation of `pb index` — invoke pbc --db, then post-process."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
from collections.abc import Callable, Sequence
from pathlib import Path

from pb.pipeline.db import setup_db_extras
from pb.pipeline.env import env
from pb.pipeline.metrics import compute_metrics
from pb.pipeline.reporter import DiagnosticsCollector, Reporter


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


def _prepare_run(
    src_dir: Path,
    db: str,
    binary: Path,
    reset: bool,
    dialect: str,
    ddl: Sequence[str],
    default_namespace: str | None,
    profile: bool = False,
) -> tuple[Path, str, list[str], str | None]:
    """Resolve src_dir, build pbc's argv, and normalize default_namespace.

    Shared by `run()`'s synchronous path and `IndexJob`'s background-thread
    path so the argv/normalization policy is single-sourced.

    Returns (resolved_src_dir, db_new_path, argv, normalized_default_namespace).
    """
    # Normalized once, here, at the single choke point every caller (index/
    # explore) goes through: catalog namespaces are always lowercased by
    # ddl.py's _table_ident regardless of --ddl tag casing, so a raw-case
    # --default-namespace value (e.g. "CLIMS") would otherwise never match
    # and silently resolve nothing — confirmed via a real multi-schema
    # reindex (Plan 157 Phase 4/5). Also keeps metadata's stored value
    # consistent with /api/schemas' (catalog-derived, lowercase) namespaces,
    # which the UI's schema picker compares directly.
    if default_namespace:
        default_namespace = default_namespace.lower()

    src_dir = src_dir.resolve()
    db_new = db + ".new"

    if reset and Path(db).exists():
        Path(db).unlink()

    # sys.executable is always defined for a running interpreter -- no
    # discovery needed. pbc launches the SQL bridge worker as
    # `sys.executable -m pb.pipeline.bridge.sql_worker`; that module's
    # location is fixed within this same distribution, so if this code is
    # running at all, the worker module is importable under this exact
    # interpreter too.
    argv = [
        str(binary), "-i", str(src_dir), "--db", db_new, "--sql-dialect", dialect,
        "--sql-worker-python", sys.executable,
    ]
    for d in ddl:
        argv += ["--ddl", d]
    if default_namespace:
        argv += ["--default-namespace", default_namespace]
    if profile:
        argv += ["+RTS", "-sstderr", "-RTS"]

    return src_dir, db_new, argv, default_namespace


def _run_pbc(argv: list[str], on_event: Callable[[dict], None]) -> tuple[int, list[str]]:
    """Spawn pbc and feed its parsed stderr JSONL events to on_event.

    Returns (returncode, unparsed raw stderr lines). Shared by `run()`'s
    synchronous path and `IndexJob`'s background-thread path -- they differ
    only in what they attach to on_event, not in the subprocess/threading
    logic itself.
    """
    run_env = os.environ.copy()
    raw_stderr_lines: list[str] = []

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
                on_event(json.loads(line))
            except json.JSONDecodeError:
                raw_stderr_lines.append(line)

    reader = threading.Thread(target=_read_stderr, daemon=True)
    reader.start()
    proc.wait()
    reader.join()

    return proc.returncode, raw_stderr_lines


def run(
    src_dir: Path,
    db: str,
    binary: Path,
    reporter: Reporter,
    reset: bool = False,
    dialect: str = "oracle",
    input_path: Path | None = None,
    ddl: Sequence[str] = (),
    default_namespace: str | None = None,
    diagnostics_report_path: str | None = None,
    profile: bool = False,
) -> None:
    src_dir, db_new, argv, default_namespace = _prepare_run(
        src_dir, db, binary, reset, dialect, ddl, default_namespace, profile=profile,
    )

    errors = 0
    collector = DiagnosticsCollector() if diagnostics_report_path else None

    try:
        with reporter.runner_progress() as prog:

            def on_event(ev: dict) -> None:
                prog.on_event(ev)
                if collector is not None:
                    collector.on_event(ev)

            returncode, raw_stderr_lines = _run_pbc(argv, on_event)
    finally:
        if collector is not None and diagnostics_report_path:
            collector.write(diagnostics_report_path)

    parsed = prog.parsed_count

    if returncode != 0:
        import typer
        typer.echo(f"pbc failed (exit {returncode}):", err=True)
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
        if default_namespace:
            conn.execute(
                "INSERT OR REPLACE INTO metadata VALUES (?, ?)",
                ["default_namespace", default_namespace],
            )

    Path(db_new).rename(db)

    with env.storage.db_connection(db) as conn, reporter.analyze_progress() as progress:
        progress.start_step("compute metrics")
        compute_metrics(conn, progress)
        sql_parse_failures = env.storage.count_sql_parse_failures(conn)

    reporter.done(parsed=parsed, errors=errors, sql_parse_failures=sql_parse_failures)
