"""Write-impact analysis: which PB objects are affected by a table/column change."""
from __future__ import annotations

from collections import defaultdict

import typer

from pb_cli.shell.db import db_connection


def run_impact(
    table: str,
    column: str | None = None,
    db: str = "pb.duckdb",
) -> None:
    """
    Report all objects affected if `table` (or `table.column`) changes.

    Levels:
      DIRECT    — objects that directly access the table in SQL or DW retrieve
      INHERITED — objects that inherit from a direct accessor
    """
    if not table:
        typer.echo("error: --table is required", err=True)
        raise typer.Exit(1)

    with db_connection(db, read_only=True) as conn:
        if column:
            direct_ps = conn.execute("""
                SELECT DISTINCT object, proc_name, operation, 'powerscript' AS source
                FROM sql_statements
                WHERE ? = ANY(tables) AND ? = ANY(columns)
            """, [table, column]).fetchall()
            direct_dw = conn.execute("""
                SELECT DISTINCT dw_name AS object, NULL AS proc_name,
                                'SELECT' AS operation, 'datawindow' AS source
                FROM dw_retrieve_columns
                WHERE table_name = ? AND column_name = ?
            """, [table, column]).fetchall()
        else:
            direct_ps = conn.execute("""
                SELECT DISTINCT object, proc_name, operation, 'powerscript' AS source
                FROM all_sql_tables WHERE table_name = ? AND source = 'powerscript'
            """, [table]).fetchall()
            direct_dw = conn.execute("""
                SELECT DISTINCT object, NULL, 'SELECT', 'datawindow'
                FROM all_sql_tables WHERE table_name = ? AND source = 'datawindow'
            """, [table]).fetchall()

        direct = [
            {"object": r[0], "proc_name": r[1], "operation": r[2], "source": r[3]}
            for r in direct_ps + direct_dw
        ]
        direct_objects = list({r["object"] for r in direct})

        if not direct_objects:
            typer.echo(
                f"No references found for table '{table}'"
                + (f", column '{column}'" if column else "")
            )
            return

        placeholders = ", ".join("?" * len(direct_objects))
        inherited = conn.execute(f"""
            WITH RECURSIVE desc_cte AS (
                SELECT from_object AS obj, to_object AS via, 1 AS depth
                FROM inherits
                WHERE to_object IN ({placeholders})
                UNION ALL
                SELECT i.from_object, dc.via, dc.depth + 1
                FROM inherits i
                JOIN desc_cte dc ON i.to_object = dc.obj
                WHERE dc.depth < 15
            )
            SELECT DISTINCT obj, via, min(depth) AS depth
            FROM desc_cte
            GROUP BY obj, via
            ORDER BY depth, via, obj
        """, direct_objects).fetchall()

    _print_impact_report(table, column, direct, inherited)


def _print_impact_report(
    table: str,
    column: str | None,
    direct: list[dict],
    inherited: list[tuple],
) -> None:
    target = f"{table}.{column}" if column else table
    typer.echo(f"\nWrite-impact analysis: {target}")
    typer.echo("=" * (len(target) + 25))

    by_op: dict[str, list[str]] = defaultdict(list)
    for r in direct:
        label = r["object"]
        if r["proc_name"]:
            label += f" / {r['proc_name']}"
        by_op[f"{r['source']}:{r['operation']}"].append(label)

    unique_objects = {r["object"] for r in direct}
    typer.echo(f"\nDIRECT ({len(direct)} references across {len(unique_objects)} objects):")
    for op_key in sorted(by_op):
        source, op = op_key.split(":", 1)
        badge = f"[{source.upper()[:2]} {op}]"
        for label in sorted(by_op[op_key]):
            typer.echo(f"  {badge:<18} {label}")

    if inherited:
        typer.echo(f"\nINHERITED ({len(inherited)} descendants inherit access via ancestry):")
        for obj, via, depth in inherited:
            indent = "  " + "  " * (depth - 1)
            typer.echo(f"{indent}{obj}  (via {via}, depth {depth})")
    else:
        typer.echo("\nINHERITED: none")

    typer.echo()
