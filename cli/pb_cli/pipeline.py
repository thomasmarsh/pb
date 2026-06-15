"""Implementation of `pb ingest` — incremental parse → index → analyze pipeline."""
from __future__ import annotations

import shutil
from pathlib import Path

import duckdb

from pb_cli.analyze import run as _analyze
from pb_cli.common import create_schema, drop_tables
from pb_cli.index import ingest_batch
from pb_cli.parse import parse_stream
from pb_cli.reporter import Reporter
from pb_cli.state import (
    build_subset_tmpdir,
    create_state_table,
    delete_file_rows,
    diff_state,
    hash_source_dir,
    load_file_state,
    save_file_state,
)


def run(
    src_dir: Path, db: str, binary: Path, reporter: Reporter,
    reset: bool = False, dialect: str = 'oracle',
) -> None:
    src_dir = src_dir.resolve()  # normalise /var → /private/var symlink on macOS
    conn = duckdb.connect(db)
    if reset:
        drop_tables(conn)
    create_schema(conn)
    create_state_table(conn)

    with reporter.status('Scanning source files...'):
        current = hash_source_dir(src_dir)
    stored = load_file_state(conn)
    diff = diff_state(current, stored)

    if not diff.new and not diff.changed and not diff.deleted:
        reporter.done(parsed=0, errors=0, diff=diff)
        conn.close()
        return

    for path in diff.deleted + diff.changed:
        delete_file_rows(conn, path)

    to_parse = diff.new + diff.changed
    if not to_parse:
        conn.close()
        _analyze(db, reporter)
        reporter.done(parsed=0, errors=0, diff=diff)
        return

    objects, errors = _parse_subset(src_dir, binary, to_parse, reporter)

    with reporter.indexing_step() as complete:
        row_count = ingest_batch(objects, conn, dialect)
        complete(row_count)

    parsed_files = {obj['file'] for obj in objects}
    save_file_state(conn, {f: current[f] for f in to_parse if f in parsed_files})
    conn.close()

    _analyze(db, reporter)
    reporter.done(parsed=len(to_parse), errors=errors, rows=row_count, diff=diff)


def _parse_subset(
    src_dir: Path, binary: Path, to_parse: list[str], reporter: Reporter,
) -> tuple[list[dict], int]:
    tmpdir = build_subset_tmpdir(src_dir, to_parse)
    try:
        objects: list[dict] = []
        with reporter.parse_progress(len(to_parse), 'Parsing') as progress:
            for is_err, obj in parse_stream(tmpdir, binary, remap_from=tmpdir, remap_to=src_dir):
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
