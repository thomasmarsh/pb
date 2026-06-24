"""Tests for pb_cli.queries auto-registration."""

import inspect

import duckdb
import typer

from pb_cli.shell.build import find_repo
from pb_cli.shell.db import parse_sql_file
from pb_cli.shell.env import env
from pb_cli.shell.queries import _make_command, _print_result, register_queries

REPO_ROOT = find_repo()
QUERIES_DIR = REPO_ROOT / "queries"


# ---------------------------------------------------------------------------
# _parse_sql_file
# ---------------------------------------------------------------------------


def test_parse_no_params():
    sql_file = QUERIES_DIR / "db-coverage.sql"
    desc, params, sql, _ = parse_sql_file(sql_file)
    assert desc
    assert params == []
    assert "table_name" in sql


def test_parse_int_param_with_default():
    sql_file = QUERIES_DIR / "top.sql"
    desc, params, sql, _ = parse_sql_file(sql_file)
    assert len(params) == 1
    name, typ, default = params[0]
    assert name == "n" and typ == "INT" and default == "15"
    assert "$n" in sql


def test_parse_text_param_no_default():
    sql_file = QUERIES_DIR / "callers.sql"
    desc, params, sql, _ = parse_sql_file(sql_file)
    assert len(params) == 1
    name, typ, default = params[0]
    assert name == "name" and typ == "TEXT" and default is None
    assert "$name" in sql


# ---------------------------------------------------------------------------
# register_queries
# ---------------------------------------------------------------------------


def test_all_sql_files_register(db_path):
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
        "SELECT object, name, proc_type, cyclomatic FROM compat_procedures ORDER BY cyclomatic DESC LIMIT $n", {"n": 5}
    ).fetchall()
    conn.close()
    assert len(rows) == 5
    assert rows[0][3] >= rows[-1][3]  # descending


def test_callers_returns_rows(db_path):
    conn = duckdb.connect(db_path, read_only=True)
    rows = conn.execute(
        "SELECT DISTINCT object FROM compat_calls WHERE to_name = $name ORDER BY object", {"name": "fn_sqlerror"}
    ).fetchall()
    conn.close()
    assert len(rows) > 0


def test_dead_code_returns_list(db_path):
    from pb_cli.explorer.services.analysis import get_dead_code

    conn = duckdb.connect(db_path, read_only=True)
    try:
        dead = get_dead_code(conn)
    finally:
        conn.close()
    assert isinstance(dead, list)
    if dead:
        assert {"name", "object", "proc_type", "cyclomatic"} <= dead[0].keys()


def test_ancestors_chain(db_path):
    conn = duckdb.connect(db_path, read_only=True)
    rows = conn.execute(
        """
        WITH RECURSIVE chain AS (
            SELECT from_object, to_object, 1 AS depth FROM compat_inherits
            WHERE from_object = $name
          UNION ALL
            SELECT chain.from_object, i.to_object, chain.depth + 1
            FROM compat_inherits i JOIN chain ON chain.to_object = i.from_object
        )
        SELECT depth, to_object AS parent FROM chain ORDER BY depth
    """,
        {"name": "m_misth_zpstath_grid"},
    ).fetchall()
    conn.close()
    assert len(rows) >= 1
    assert rows[0][1] == "m_main_pbgrid"


def test_pagerank_ordered(db_path):
    conn = duckdb.connect(db_path, read_only=True)
    rows = conn.execute("SELECT pagerank FROM object_metrics ORDER BY pagerank DESC LIMIT $n", {"n": 10}).fetchall()
    conn.close()
    assert len(rows) > 0
    prs = [r[0] for r in rows]
    assert prs == sorted(prs, reverse=True)


# ---------------------------------------------------------------------------
# _make_command signature construction
# ---------------------------------------------------------------------------


def test_make_command_positional_params(tmp_path):
    sql_file = tmp_path / "test.sql"
    sql_file.write_text("-- Test query\n-- :name TEXT\nSELECT * FROM t WHERE name = $name\n")
    cmd = _make_command(sql_file)
    sig = inspect.signature(cmd)
    positional = [p for p in sig.parameters.values() if p.kind == p.POSITIONAL_OR_KEYWORD and p.name != "db"]
    assert len(positional) == 1
    assert positional[0].name == "name"
    assert positional[0].annotation is str


def test_make_command_keyword_params_with_defaults(tmp_path):
    sql_file = tmp_path / "test.sql"
    sql_file.write_text("-- Test\n-- :limit INT 10\nSELECT * FROM t LIMIT $limit\n")
    cmd = _make_command(sql_file)
    sig = inspect.signature(cmd)
    kw = [p for p in sig.parameters.values() if p.kind == p.KEYWORD_ONLY and p.name != "db"]
    assert len(kw) == 1
    assert kw[0].name == "limit"
    assert kw[0].annotation is int


# ---------------------------------------------------------------------------
# _print_result formatting
# ---------------------------------------------------------------------------


def test_print_result_empty(capsys):
    class FakeCursor:
        description = [("col1",)]

        def fetchall(self):
            return []

    _print_result(FakeCursor())
    assert "(no results)" in capsys.readouterr().out


def test_print_result_with_nones(capsys):
    class FakeCursor:
        description = [("a",), ("b",)]

        def fetchall(self):
            return [(1, None), (None, "x")]

    _print_result(FakeCursor())
    out = capsys.readouterr().out
    assert "1" in out
    assert "x" in out


# ---------------------------------------------------------------------------
# register_queries empty dir
# ---------------------------------------------------------------------------


def test_register_queries_empty_dir(tmp_path, monkeypatch):
    monkeypatch.setattr(env.build, "get_queries_dir", lambda: tmp_path / "nonexistent")
    app = typer.Typer()
    register_queries(app)
    assert len(app.registered_commands) == 0
