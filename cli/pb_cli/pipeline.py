"""Implementation of `pb ingest` — incremental parse → index → analyze pipeline."""
from __future__ import annotations

import shutil
from pathlib import Path

from pb_cli.analyze import run as _analyze
from pb_cli.common import create_schema, db_connection, drop_tables
from pb_cli.core.state import diff_state
from pb_cli.index import ingest_batch
from pb_cli.reporter import Reporter
from pb_cli.shell.env import env
from pb_cli.state import (
    build_subset_tmpdir,
    create_state_table,
    delete_file_rows,
    load_file_state,
    save_file_state,
)


def run(
    src_dir: Path, db: str, binary: Path, reporter: Reporter,
    reset: bool = False, dialect: str = 'oracle',
) -> None:
    src_dir = src_dir.resolve()  # normalise /var → /private/var symlink on macOS
    to_parse = None
    errors = 0
    row_count = 0

    with db_connection(db) as conn:
        if reset:
            drop_tables(conn)
        create_schema(conn)
        create_state_table(conn)

        with reporter.status('Scanning source files...'):
            current = env.build.hash_source_dir(src_dir)
        stored = load_file_state(conn)
        diff = diff_state(current, stored)

        if not diff.new and not diff.changed and not diff.deleted:
            reporter.done(parsed=0, errors=0, diff=diff)
            return

        for path in diff.deleted + diff.changed:
            delete_file_rows(conn, path)

        to_parse = diff.new + diff.changed
        if to_parse:
            objects, errors = _parse_subset(src_dir, binary, to_parse, reporter)

            with reporter.indexing_step() as advance:
                row_count = ingest_batch(objects, conn, dialect, on_progress=advance)

            parsed_files = {obj['file'] for obj in objects}
            save_file_state(conn, {f: current[f] for f in to_parse if f in parsed_files})

    _analyze(db, reporter)
    if to_parse:
        reporter.done(parsed=len(to_parse), errors=errors, rows=row_count, diff=diff)
    else:
        reporter.done(parsed=0, errors=0, diff=diff)


def _parse_subset(
    src_dir: Path, binary: Path, to_parse: list[str], reporter: Reporter,
) -> tuple[list[dict], int]:
    tmpdir = build_subset_tmpdir(src_dir, to_parse)
    try:
        objects: list[dict] = []
        with reporter.parse_progress(len(to_parse), 'Parsing') as progress:
            for is_err, obj in env.runner.parse_stream(tmpdir, binary, remap_from=tmpdir, remap_to=src_dir):
                if is_err:
                    progress.on_error(obj)
                else:
                    try:
                        obj['source_text'] = Path(obj['file']).read_text(errors='replace')
                    except OSError:
                        obj['source_text'] = None
                    objects.append(obj)
                progress.advance()
        return objects, progress.error_count
    finally:
        shutil.rmtree(tmpdir)
