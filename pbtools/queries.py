"""Auto-register queries/*.sql files as top-level pb CLI commands."""
from __future__ import annotations

import re
from inspect import Parameter, Signature
from pathlib import Path

import duckdb
import typer

QUERIES_DIR = Path(__file__).parent.parent / "queries"

_INT_TYPES = {"INT", "INTEGER", "BIGINT"}


def _parse_sql_file(path: Path) -> tuple[str, list[tuple[str, str, str | None]], str]:
    """Return (description, params, sql).

    Leading comment block is consumed; remainder is executed verbatim.
    Param lines: ``-- :name TYPE [default]``
    """
    lines = path.read_text().splitlines()
    description = ""
    params: list[tuple[str, str, str | None]] = []
    sql_start = len(lines)
    for i, raw in enumerate(lines):
        line = raw.strip()
        if not line.startswith("--"):
            sql_start = i
            break
        m = re.match(r"^--\s+:(\w+)\s+(\w+)(?:\s+(\S+))?$", line)
        if m:
            pname, ptype, pdefault = m.groups()
            params.append((pname, ptype.upper(), pdefault))
        elif not description:
            description = line.lstrip("-").strip()
    return description, params, "\n".join(lines[sql_start:]).strip()


def _print_result(cursor) -> None:
    cols = [d[0] for d in cursor.description]
    rows = cursor.fetchall()
    if not rows:
        typer.echo("(no results)")
        return
    widths = [len(c) for c in cols]
    str_rows = [["" if v is None else str(v) for v in row] for row in rows]
    for row in str_rows:
        for i, val in enumerate(row):
            widths[i] = max(widths[i], len(val))
    typer.echo("  ".join(c.ljust(w) for c, w in zip(cols, widths)))
    typer.echo("  ".join("-" * w for w in widths))
    for row in str_rows:
        typer.echo("  ".join(val.ljust(w) for val, w in zip(row, widths)))


def _make_command(sql_file: Path):
    description, params, sql = _parse_sql_file(sql_file)
    pos_params = [(n, t, d) for n, t, d in params if d is None]
    kw_params  = [(n, t, d) for n, t, d in params if d is not None]
    all_names  = [n for n, _, _ in pos_params + kw_params]

    def _run(**kwargs):
        db = kwargs["db"]
        bound = {n: kwargs[n] for n in all_names}
        try:
            conn = duckdb.connect(db, read_only=True)
        except Exception as e:
            typer.echo(f"Cannot open {db}: {e}", err=True)
            raise typer.Exit(1)
        try:
            _print_result(conn.execute(sql, bound))
        except Exception as e:
            typer.echo(f"Query failed: {e}", err=True)
            raise typer.Exit(1)
        finally:
            conn.close()

    sig: list[Parameter] = []
    for name, typ, _ in pos_params:
        sig.append(Parameter(
            name, Parameter.POSITIONAL_OR_KEYWORD,
            annotation=int if typ in _INT_TYPES else str,
        ))
    for name, typ, default in kw_params:
        py_type = int if typ in _INT_TYPES else str
        dv = int(default) if typ in _INT_TYPES else default
        sig.append(Parameter(
            name, Parameter.KEYWORD_ONLY,
            default=typer.Option(dv, f"--{name.replace('_', '-')}"),
            annotation=py_type,
        ))
    sig.append(Parameter(
        "db", Parameter.KEYWORD_ONLY,
        default=typer.Option("pb.duckdb", "--db", help="DuckDB database path."),
        annotation=str,
    ))

    _run.__signature__ = Signature(sig)
    _run.__doc__ = description
    _run.__name__ = sql_file.stem
    return _run


def register_queries(app: typer.Typer) -> None:
    """Register every queries/*.sql file as a top-level pb command."""
    if not QUERIES_DIR.is_dir():
        return
    for sql_file in sorted(QUERIES_DIR.glob("*.sql")):
        app.command(name=sql_file.stem)(_make_command(sql_file))
