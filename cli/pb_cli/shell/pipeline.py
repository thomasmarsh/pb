"""Implementation of `pb index` — incremental parse → import → analyze pipeline."""

from __future__ import annotations

import shutil
from pathlib import Path

from pb_cli.core.models import ParseErrorRow
from pb_cli.core.state import diff_state
from pb_cli.shell.env import env
from pb_cli.shell.reporter import Reporter
from pb_cli.shell.runner import extract_line


def db_is_current(input_path: Path, db: str) -> bool:
    """Return True if pb.duckdb already reflects the source input.

    For .pbl directories, compares per-.pbl-file hashes via file_state.
    For plain directories, compares per-.sr*-file hashes via file_state.
    """
    if not Path(db).exists():
        return False
    try:
        with env.storage.db_connection(db, read_only=True) as conn:
            p = input_path.resolve()
            is_pbl = p.is_dir() and any(f.suffix.lower() == ".pbl" for f in p.iterdir() if f.is_file())
            if is_pbl:
                current = env.build.hash_pbl_dir(input_path)
            else:
                current = env.build.hash_source_dir(input_path)
            stored = env.storage.load_file_state(conn)
            # Only compare entries relevant to this input type
            ext = ".pbl" if is_pbl else None
            if ext:
                stored = {k: v for k, v in stored.items() if k.endswith(ext)}
            diff = diff_state(current, stored)
            return not diff.new and not diff.changed and not diff.deleted
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
    src_dir = src_dir.resolve()  # normalise /var → /private/var symlink on macOS
    to_parse = None
    errors = 0
    row_count = 0

    with env.storage.db_connection(db) as conn:
        if reset:
            env.storage.drop_tables(conn)
        env.storage.create_schema(conn)
        env.storage.create_state_table(conn)
        conn.execute("INSERT OR REPLACE INTO metadata VALUES (?, ?)", ["ingestion_root", str(src_dir.resolve())])

        with reporter.status("Scanning source files..."):
            current = env.build.hash_source_dir(src_dir)
        stored = env.storage.load_file_state(conn)
        diff = diff_state(current, stored)

        if not diff.new and not diff.changed and not diff.deleted:
            reporter.done(parsed=0, errors=0, diff=diff, sql_parse_failures=env.storage.count_sql_parse_failures(conn))
            return

        for path in diff.deleted + diff.changed:
            env.storage.delete_file_rows(conn, path)

        to_parse = diff.new + diff.changed
        if to_parse:
            objects, errors, parse_errors = _parse_subset(src_dir, binary, to_parse, reporter)

            with reporter.indexing_step() as advance:
                row_count = env.storage.import_batch(objects, conn, dialect, on_progress=advance)
            env.storage.insert_parse_errors(conn, parse_errors)

            parsed_files = {obj["file"] for obj in objects}
            env.storage.save_file_state(conn, {f: current[f] for f in to_parse if f in parsed_files})

        if input_path is not None:
            p = input_path.resolve()
            if p.is_dir() and any(f.suffix.lower() == ".pbl" for f in p.iterdir() if f.is_file()):
                pbl_hashes = env.build.hash_pbl_dir(input_path)
                if pbl_hashes:
                    env.storage.save_file_state(conn, pbl_hashes)

    with env.storage.db_connection(db) as conn, reporter.analyze_progress() as progress:
        env.storage.compute_metrics(conn, progress)
        env.storage.build_type_tables(conn)
        sql_parse_failures = env.storage.count_sql_parse_failures(conn)

    if to_parse:
        reporter.done(
            parsed=len(to_parse), errors=errors, rows=row_count, diff=diff, sql_parse_failures=sql_parse_failures
        )
    else:
        reporter.done(parsed=0, errors=0, diff=diff, sql_parse_failures=sql_parse_failures)


def _parse_subset(
    src_dir: Path,
    binary: Path,
    to_parse: list[str],
    reporter: Reporter,
) -> tuple[list[dict], int, list[ParseErrorRow]]:
    tmpdir = env.storage.build_subset_tmpdir(src_dir, to_parse)
    try:
        objects: list[dict] = []
        parse_errors: list[ParseErrorRow] = []
        with reporter.parse_progress(len(to_parse), "Parsing") as progress:
            for is_err, obj in env.runner.parse_stream(tmpdir, binary, remap_from=tmpdir, remap_to=src_dir):
                if is_err:
                    progress.on_error(obj)
                    message = obj.get("error", "")
                    try:
                        snippet = Path(obj["file"]).read_text(errors="replace")
                    except OSError:
                        snippet = None
                    parse_errors.append(
                        ParseErrorRow(obj.get("file", ""), "powerscript", message, None, None, extract_line(message), snippet)
                    )
                else:
                    try:
                        obj["source_text"] = Path(obj["file"]).read_text(errors="replace")
                    except OSError:
                        obj["source_text"] = None
                    try:
                        obj["file"] = str(Path(obj["file"]).relative_to(src_dir))
                    except ValueError:
                        pass
                    objects.append(obj)
                progress.advance()
        return objects, progress.error_count, parse_errors
    finally:
        shutil.rmtree(tmpdir)
