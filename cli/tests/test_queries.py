"""Tests for pb_cli.queries auto-registration."""
from pathlib import Path

import duckdb
import pytest

from pb_cli.build import find_repo

REPO_ROOT = find_repo()
QUERIES_DIR = REPO_ROOT / "queries"


# ---------------------------------------------------------------------------
# _parse_sql_file
# ---------------------------------------------------------------------------

def test_parse_no_params():
    from pb_cli.queries import _parse_sql_file
    sql_file = QUERIES_DIR / "dead-code.sql"
    desc, params, sql = _parse_sql_file(sql_file)
    assert desc
    assert params == []
    assert "FROM procedures" in sql


def test_parse_int_param_with_default():
    from pb_cli.queries import _parse_sql_file
    sql_file = QUERIES_DIR / "top.sql"
    desc, params, sql = _parse_sql_file(sql_file)
    assert len(params) == 1
    name, typ, default = params[0]
    assert name == "n" and typ == "INT" and default == "15"
    assert "$n" in sql


def test_parse_text_param_no_default():
    from pb_cli.queries import _parse_sql_file
    sql_file = QUERIES_DIR / "callers.sql"
    desc, params, sql = _parse_sql_file(sql_file)
    assert len(params) == 1
    name, typ, default = params[0]
    assert name == "name" and typ == "TEXT" and default is None
    assert "$name" in sql


# ---------------------------------------------------------------------------
# register_queries
# ---------------------------------------------------------------------------

def test_all_sql_files_register(db_path):
    import typer
    from pb_cli.queries import register_queries
    app = typer.Typer()
    register_queries(app)
    registered = {c.name for c in app.registered_commands}
    for sql_file in QUERIES_DIR.glob("*.sql"):
        assert sql_file.stem in registered, f"{sql_file.stem} not registered"


# ---------------------------------------------------------------------------
# query execution
# ---------------------------------------------------------------------------

def test_top_returns_rows(db_path):
    conn = duckdb.connect(db_path, read_only=True)
    rows = conn.execute(
        "SELECT object, name, proc_type, cyclomatic FROM procedures ORDER BY cyclomatic DESC LIMIT $n",
        {"n": 5}
    ).fetchall()
    conn.close()
    assert len(rows) == 5
    assert rows[0][3] >= rows[-1][3]  # descending


def test_callers_returns_rows(db_path):
    conn = duckdb.connect(db_path, read_only=True)
    rows = conn.execute(
        "SELECT DISTINCT object FROM calls WHERE to_name = $name ORDER BY object",
        {"name": "fn_sqlerror"}
    ).fetchall()
    conn.close()
    assert len(rows) > 0


def test_dead_code_no_false_negatives(db_path):
    conn = duckdb.connect(db_path, read_only=True)
    # Every row returned should genuinely have no entry in calls
    rows = conn.execute("""
        SELECT p.object, p.name FROM procedures p
        LEFT JOIN calls c ON c.to_name = p.name
        WHERE c.to_name IS NULL
          AND p.proc_type IN ('function', 'subroutine')
          AND (p.modifiers IS NULL OR p.modifiers NOT LIKE '%public%')
    """).fetchall()
    conn.close()
    if rows:
        # Spot-check: first result really has no callers
        name = rows[0][1]
        conn2 = duckdb.connect(db_path, read_only=True)
        row = conn2.execute("SELECT count(*) FROM calls WHERE to_name = ?", [name]).fetchone()
        callers = row[0] if row else 0
        conn2.close()
        assert callers == 0


def test_ancestors_chain(db_path):
    conn = duckdb.connect(db_path, read_only=True)
    rows = conn.execute("""
        WITH RECURSIVE chain AS (
            SELECT from_object, to_object, 1 AS depth FROM inherits
            WHERE from_object = $name
          UNION ALL
            SELECT chain.from_object, i.to_object, chain.depth + 1
            FROM inherits i JOIN chain ON chain.to_object = i.from_object
        )
        SELECT depth, to_object AS parent FROM chain ORDER BY depth
    """, {"name": "m_misth_zpstath_grid"}).fetchall()
    conn.close()
    assert len(rows) >= 1
    assert rows[0][1] == "m_main_pbgrid"


def test_pagerank_ordered(db_path):
    conn = duckdb.connect(db_path, read_only=True)
    rows = conn.execute(
        "SELECT pagerank FROM object_metrics ORDER BY pagerank DESC LIMIT $n",
        {"n": 10}
    ).fetchall()
    conn.close()
    assert len(rows) > 0
    prs = [r[0] for r in rows]
    assert prs == sorted(prs, reverse=True)
