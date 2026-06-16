"""PowerBuilder SQL parser — wraps sqlglot with PB-specific pre-processing."""

from __future__ import annotations

import re

import sqlglot
from sqlglot import exp

# sqlglot embeds raw ANSI underline codes (\x1b[4m...\x1b[0m) around the
# offending token in ParseError messages, for terminal display. The Raw tab
# isn't a terminal, so the escape bytes render as literal "[4m...[0m" — but
# the highlighted token itself is useful, so swap the ANSI markers for plain
# »...« brackets rather than discarding the highlight entirely.
_ANSI_HIGHLIGHT_RE = re.compile(r"\x1b\[4m(.*?)\x1b\[0m")

# Statements with no parseable SQL structure — extract metadata only
_SKIP_RE = re.compile(
    r"^\s*(CONNECT|DISCONNECT|OPEN|CLOSE|FETCH|EXECUTE\s+(?:IMMEDIATE|PROCEDURE)"
    r"|DECLARE\s+\w+\s+DYNAMIC\s+CURSOR\s+FOR\s+\w+\s*;?\s*$"
    r"|DECLARE\s+\w+\s+PROCEDURE\s+FOR\s+\w+)",
    re.I,
)

# PB-specific rewrites applied in order before feeding to sqlglot.
# Each entry is (compiled_pattern, replacement).  Replacement may be a string
# or a callable (re.sub-compatible).
_REWRITES: list[tuple[re.Pattern, object]] = [
    # Strip PB's "// line comment" — not a standard SQL line-comment marker
    # (sqlglot reads bare "//" as division), so it must go before any other
    # rewrite that might be confused by trailing comment text.
    (re.compile(r"//[^\n]*"), ""),
    # Strip the PB transaction-object clause: COMMIT/ROLLBACK/SELECT/UPDATE/
    # DELETE/INSERT ... USING <transobject>. Not standard SQL. Negative
    # lookahead on "(" avoids clobbering real `JOIN ... USING (col)` syntax.
    (re.compile(r"\bUSING\s+\w+\b(?!\s*\()", re.I), ""),
    # Strip PB host-variable INTO clause: SELECT ... INTO :v1, :v2 FROM ...
    # INSERT INTO tablename is safe — table names don't start with ':'.
    (re.compile(r"\bINTO\b\s+:\w+(?:\s*,\s*:\w+)*", re.I), ""),
    # Strip DECLARE cursor wrapper; keep inner SELECT
    (
        re.compile(
            r"DECLARE\s+\w+\s+CURSOR\s+FOR\s*\(?(SELECT.*)\)?",
            re.I | re.S,
        ),
        lambda m: m.group(1),
    ),
]


def pb_sql_to_standard(sql_text: str) -> str | None:
    """Pre-process PB SQL into standard SQL. Returns None for unstructured forms."""
    if _SKIP_RE.match(sql_text.strip()):
        return None
    result = sql_text
    for pattern, repl in _REWRITES:
        result = pattern.sub(repl, result)
    return result


def extract_tables(ast) -> list[str]:
    return [t.name for t in ast.find_all(exp.Table) if t.name]


def extract_columns(ast) -> list[str]:
    return [c.name for c in ast.find_all(exp.Column) if c.name]


def parse_pb_sql(
    raw_sql: str,
    dialect: str = "oracle",
) -> tuple[list[dict] | None, list[str], list[str], dict]:
    """Parse PB embedded SQL.

    Returns (parsed_dict, tables, columns, metadata).
    parsed_dict is None for unstructured forms (cursors, dynamic SQL, connections).
    """
    operation = raw_sql.strip().split()[0].upper() if raw_sql.strip() else "UNKNOWN"
    meta = {
        "operation": operation,
        "has_into": "INTO :" in raw_sql.upper(),
        "has_cursor": "CURSOR" in raw_sql.upper(),
    }

    standard = pb_sql_to_standard(raw_sql)
    if standard is None:
        return None, [], [], meta

    dialects = [dialect] if dialect == "oracle" else [dialect, "oracle"]
    last_error: Exception | None = None
    for d in dialects:
        try:
            ast = sqlglot.parse_one(standard, dialect=d, error_level=sqlglot.ErrorLevel.RAISE)
            tables = extract_tables(ast)
            columns = extract_columns(ast)
            return ast.dump(), tables, columns, meta
        except Exception as e:
            last_error = e
            continue

    if last_error is not None:
        meta["error"] = _ANSI_HIGHLIGHT_RE.sub(r"»\1«", str(last_error))
    return None, [], [], meta
