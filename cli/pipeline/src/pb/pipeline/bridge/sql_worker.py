"""SQL bridge worker process.

Reads length-prefixed JSON requests from stdin, parses each SQL string via
sqlglot, and writes length-prefixed JSON responses to stdout.

Wire format: 4-byte big-endian uint32 length header, then UTF-8 JSON body.

Request:  {"sql": "SELECT ...", "dialect": "oracle"}
Response: {"tables": [...], "columns": [...], "operation": "SELECT", "parse_ok": true,
           "column_refs": [{"namespace": null, "table": ..., "column": ..., "is_write": ...}, ...],
           "row_filters": [{"namespace": null, "table": ..., "column": ..., "op": ..., "values": [...]}, ...]}

A request with "kind": "ddl" is dispatched to parse_ddl instead:

Request:  {"kind": "ddl", "ddl": "CREATE TABLE ...", "dialect": "mysql", "namespace": "CLIMS"}
Response: {"kind": "ddl", "parse_ok": true,
           "catalog": {"tables": [...], "primary_keys": [...], "foreign_keys": [...], "checks": [...]},
           "stats": {"statements_total": N, "statements_parsed": N, "statements_skipped": N,
                      "skipped_previews": ["[unparsed] ...", "[unresolved view] ...", ...]},
           "error": null}

On a hard failure (an exception outside of sqlglot's own per-statement WARN-level
recovery, e.g. a totally unreadable file), "parse_ok" is false, "catalog" is empty,
and "error" carries the exception message instead of being silently swallowed.
"""

from __future__ import annotations

import json
import logging
import struct
import sys
from dataclasses import asdict

from pb.lib.ddl import Catalog, DdlStats, parse_ddl
from pb.lib.sql import parse_pb_sql

# sqlglot's own internal logger writes truncated RAW SQL -- including real
# table/schema/column names from whatever DDL/SQL this worker is asked to
# parse -- to stderr on every WARN-level parse fallback (logger.warning)
# and on each individual parse error under WARN error_level (logger.error).
# That doesn't corrupt this process's stdout wire protocol, but it does
# leak customer schema content into stderr, which `pb index` and anything
# else driving this worker will surface to whoever is watching. CRITICAL
# is the only threshold that silences both calls (ERROR alone still lets
# logger.error(...) through -- confirmed the same way for the standalone
# scripts/diagnose_ddl_skips.py diagnostic).
logging.getLogger("sqlglot").setLevel(logging.CRITICAL)

_HEADER = struct.Struct(">I")


def _read_msg(stream) -> dict | None:
    header = stream.read(4)
    if len(header) < 4:
        return None
    (length,) = _HEADER.unpack(header)
    body = stream.read(length)
    if len(body) < length:
        return None
    return json.loads(body)


def _write_msg(stream, obj: dict) -> None:
    body = json.dumps(obj).encode("utf-8")
    stream.write(_HEADER.pack(len(body)))
    stream.write(body)
    stream.flush()


_EMPTY_CATALOG = asdict(Catalog(tables=[], primary_keys=[], foreign_keys=[], checks=[]))
_EMPTY_STATS = asdict(DdlStats(statements_total=0, statements_parsed=0, statements_skipped=0))


def _handle_ddl(msg: dict) -> dict:
    ddl = msg.get("ddl", "")
    dialect = msg.get("dialect", "mysql")
    namespace = msg.get("namespace")
    try:
        catalog, stats = parse_ddl(ddl, dialect, namespace)
        return {
            "kind": "ddl",
            "parse_ok": True,
            "catalog": asdict(catalog),
            "stats": asdict(stats),
            "error": None,
        }
    except Exception as exc:
        return {
            "kind": "ddl",
            "parse_ok": False,
            "catalog": _EMPTY_CATALOG,
            "stats": _EMPTY_STATS,
            "error": str(exc),
        }


def main() -> None:
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer

    while True:
        msg = _read_msg(stdin)
        if msg is None:
            break

        if msg.get("kind") == "ddl":
            _write_msg(stdout, _handle_ddl(msg))
            continue

        sql = msg.get("sql", "")
        dialect = msg.get("dialect", "oracle")

        try:
            parsed, tables, columns, meta = parse_pb_sql(sql, dialect)
            response: dict = {
                "tables": tables,
                "columns": columns,
                "operation": meta.get("operation", "UNKNOWN"),
                "parse_ok": parsed is not None,
                "column_refs": meta.get("column_refs", []),
                "row_filters": meta.get("row_filters", []),
            }
        except Exception:
            response = {
                "tables": [],
                "columns": [],
                "operation": "UNKNOWN",
                "parse_ok": False,
                "column_refs": [],
                "row_filters": [],
            }

        _write_msg(stdout, response)


if __name__ == "__main__":
    main()
