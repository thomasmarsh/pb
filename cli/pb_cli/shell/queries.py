"""Auto-register queries/*.sql files as commands on a typer sub-app (pb query <name>)."""

from __future__ import annotations

from inspect import Parameter, Signature
from pathlib import Path

import duckdb
import typer

from pb_cli.shell.db import parse_sql_file
from pb_cli.shell.env import env

_INT_TYPES = {"INT", "INTEGER", "BIGINT"}


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
    description, params, sql, _ = parse_sql_file(sql_file)
    pos_params = [(n, t, d) for n, t, d in params if d is None]
    kw_params = [(n, t, d) for n, t, d in params if d is not None]
    all_names = [n for n, _, _ in pos_params + kw_params]

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
        sig.append(
            Parameter(
                name,
                Parameter.POSITIONAL_OR_KEYWORD,
                annotation=int if typ in _INT_TYPES else str,
            )
        )
    for name, typ, default in kw_params:
        py_type = int if typ in _INT_TYPES else str
        dv = int(default) if typ in _INT_TYPES else default
        sig.append(
            Parameter(
                name,
                Parameter.KEYWORD_ONLY,
                default=typer.Option(dv, f"--{name.replace('_', '-')}"),
                annotation=py_type,
            )
        )
    sig.append(
        Parameter(
            "db",
            Parameter.KEYWORD_ONLY,
            default=typer.Option("pb.duckdb", "--db", help="DuckDB database path."),
            annotation=str,
        )
    )

    _run.__signature__ = Signature(sig)  # type: ignore[attr-defined]
    _run.__doc__ = description
    _run.__name__ = sql_file.stem
    return _run


def register_queries(app: typer.Typer) -> None:
    """Register every queries/*.sql file as a command on the given typer app."""
    queries_dir = env.build.get_queries_dir()
    if not queries_dir.is_dir():
        return
    for sql_file in sorted(queries_dir.glob("*.sql")):
        app.command(name=sql_file.stem)(_make_command(sql_file))
