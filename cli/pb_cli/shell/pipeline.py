"""Implementation of `pb index` — incremental parse → import → analyze pipeline."""

from __future__ import annotations

import shutil
from pathlib import Path

from pb_cli.core.models import ParseErrorRow
from pb_cli.core.state import diff_state
from pb_cli.shell.env import env
from pb_cli.shell.reporter import Reporter
from pb_cli.shell.runner import extract_line


def run(
    src_dir: Path,
    db: str,
    binary: Path,
    reporter: Reporter,
    reset: bool = False,
    dialect: str = "oracle",
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

    with env.storage.db_connection(db) as conn, reporter.analyze_progress() as progress:
        env.storage.compute_metrics(conn, progress)
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
                    objects.append(obj)
                progress.advance()
        return objects, progress.error_count, parse_errors
    finally:
        shutil.rmtree(tmpdir)
