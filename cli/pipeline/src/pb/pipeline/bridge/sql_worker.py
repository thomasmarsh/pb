"""SQL bridge worker process.

Reads length-prefixed JSON requests from stdin, parses each SQL string via
sqlglot, and writes length-prefixed JSON responses to stdout.

Wire format: 4-byte big-endian uint32 length header, then UTF-8 JSON body.

Request:  {"sql": "SELECT ...", "dialect": "oracle"}
Response: {"tables": [...], "columns": [...], "operation": "SELECT", "parse_ok": true,
           "column_refs": [{"namespace": null, "table": ..., "column": ..., "is_write": ...}, ...],
           "row_filters": [{"namespace": null, "table": ..., "column": ..., "op": ..., "values": [...]}, ...]}
"""

from __future__ import annotations

import json
import struct
import sys

from pb.lib.sql import parse_pb_sql

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


def main() -> None:
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer

    while True:
        msg = _read_msg(stdin)
        if msg is None:
            break

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
