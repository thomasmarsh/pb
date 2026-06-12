"""
pb index — populate pb.duckdb from pb-runner JSONL output.

Usage (CLI):
    pb-runner -i <srcdir> --jsonl | pb index [DB]
    pb-runner -i <srcdir> --jsonl | pb index < codebase.jsonl

Library:
    from pbtools.index import run_from_jsonl_lines
"""
import json
import sys
from typing import Iterable

import duckdb

from pbtools.common import TABLES, INSERT, create_schema


def run(db: str = 'pb.duckdb') -> None:
    """Read JSONL from stdin and populate the database."""
    run_from_jsonl_lines(sys.stdin, db)


def run_from_jsonl_lines(lines: Iterable[str], db: str = 'pb.duckdb') -> None:
    conn = duckdb.connect(db)
    create_schema(conn)

    rows: dict[str, list] = {t: [] for t in TABLES}
    for line in lines:
        line = line.strip() if isinstance(line, str) else line.strip()
        if not line:
            continue
        obj = json.loads(line)
        ingest_file(obj, rows)

    for table, data in rows.items():
        if data:
            conn.executemany(INSERT[table], data)

    conn.close()
    total = sum(len(v) for v in rows.values())
    print(f"Indexed {total} rows into {db}", file=sys.stderr)


def ingest_file(obj: dict, rows: dict) -> None:
    file = obj.get('file', '')
    kind = obj.get('kind', '')
    name = extract_object_name(obj)
    ancestor = obj.get('meta', {}).get('ancestor')

    rows['objects'].append((file, name, kind, ancestor))
    if ancestor:
        rows['inherits'].append((name, ancestor))

    if kind == 'powerscript':
        ingest_ps(obj, file, rows)
    elif kind == 'datawindow':
        ingest_dw(obj, file, rows)


def extract_object_name(obj: dict) -> str:
    """Primary object name from E1 file-level meta, falling back to filename stem."""
    if name := obj.get('meta', {}).get('object'):
        return name
    stem = obj.get('file', '').split('/')[-1]
    return stem.rsplit('.', 1)[0] if '.' in stem else stem


def ingest_ps(obj: dict, file: str, rows: dict) -> None:
    for proc_type, key in [
        ('function',   'functions'),
        ('subroutine', 'subroutines'),
        ('event',      'events'),
        ('on',         'onBlocks'),
    ]:
        for block in obj.get(key, []):
            rows['procedures'].append(_proc_row(file, proc_type, block))


def _proc_row(file: str, proc_type: str, block: dict) -> tuple:
    meta = block.get('meta') or {}
    object_name = meta.get('object', '')
    start_line  = meta.get('startLine')
    end_line    = meta.get('endLine')

    if proc_type == 'on':
        name        = block.get('event', '')
        modifiers   = None
        params      = None
        return_type = None
    else:
        sig         = block.get('sig') or {}
        name        = sig.get('name', '')
        mods        = sig.get('modifiers') or []
        modifiers   = ' '.join(mods) if mods else None
        params      = sig.get('params') or sig.get('rawSig')
        return_type = sig.get('returnType')

    body_json = json.dumps(block.get('body', []))
    return (file, object_name, proc_type, name, modifiers, params,
            return_type, start_line, end_line, body_json)


def ingest_dw(obj: dict, file: str, rows: dict) -> None:
    dw_name = extract_object_name(obj)

    for ctrl in obj.get('controls', []):
        rows['dw_controls'].append(_ctrl_row(file, dw_name, ctrl))

    tbl      = obj.get('table') or {}
    retrieve = tbl.get('retrieve') or {}
    if not isinstance(retrieve, dict):
        return

    for t in retrieve.get('tables', []):
        rows['dw_retrieve_tables'].append((file, dw_name, t))

    for col in retrieve.get('columns', []):
        parts = col.split('.', 1)
        rows['dw_retrieve_columns'].append((
            file, dw_name, col,
            parts[0] if len(parts) == 2 else None,
            parts[1] if len(parts) == 2 else col,
        ))

    for i, w in enumerate(retrieve.get('where', [])):
        rows['dw_retrieve_where'].append((
            file, dw_name, i,
            w.get('exp1'), w.get('op'), w.get('exp2'), w.get('logic'),
        ))

    for a in retrieve.get('arguments', []):
        rows['dw_arguments'].append((file, dw_name, a.get('name'), a.get('type')))


def _ctrl_row(file: str, dw_name: str, ctrl: dict) -> tuple:
    band = ctrl.get('band')
    if isinstance(band, dict):
        band = band.get('tag')
    meta = ctrl.get('meta') or {}
    return (
        file, dw_name,
        ctrl.get('name'),
        ctrl.get('type'),
        band,
        ctrl.get('x'), ctrl.get('y'), ctrl.get('width'), ctrl.get('height'),
        ctrl.get('expression'),
        ctrl.get('tab_seq'),
        meta.get('sourceLine'),
    )
