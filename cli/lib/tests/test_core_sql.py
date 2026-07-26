"""Unit tests for pb/lib/sql.py — 10 representative PB SQL patterns.

Tests verify table/column extraction, metadata flags, and fallback behaviour.
"""

import importlib

import pytest
from pb.lib.sql import parse_pb_sql, pb_sql_to_standard


# ──────────────────────────────────────────────────────────────────────────────
# Pattern 1: Simple SELECT with host-variable INTO clause
# ──────────────────────────────────────────────────────────────────────────────
def test_select_single_table():
    raw = "SELECT cust_name, cust_email INTO :ls_name, :ls_email FROM customer WHERE cust_id = :li_id"
    parsed, tables, columns, meta = parse_pb_sql(raw)
    assert parsed is not None, "simple SELECT should parse"
    assert "customer" in tables
    assert meta["operation"] == "SELECT"
    assert meta["has_into"] is True


# ──────────────────────────────────────────────────────────────────────────────
# Pattern 2: SELECT with JOIN across two tables
# ──────────────────────────────────────────────────────────────────────────────
def test_select_join():
    raw = (
        "SELECT o.order_id, c.cust_name "
        "INTO :li_order, :ls_name "
        "FROM orders o JOIN customer c ON o.cust_id = c.cust_id "
        "WHERE o.status = :ls_status"
    )
    parsed, tables, columns, meta = parse_pb_sql(raw)
    assert parsed is not None, "JOIN SELECT should parse"
    assert "orders" in tables
    assert "customer" in tables
    assert meta["has_into"] is True


# ──────────────────────────────────────────────────────────────────────────────
# Pattern 3: SELECT with no INTO (result set retrieval, no cursor)
# ──────────────────────────────────────────────────────────────────────────────
def test_select_no_into():
    raw = "SELECT count(*) FROM invoice WHERE invoice_date >= :ld_from AND invoice_date <= :ld_to"
    parsed, tables, columns, meta = parse_pb_sql(raw)
    assert parsed is not None
    assert "invoice" in tables
    assert meta["has_into"] is False


# ──────────────────────────────────────────────────────────────────────────────
# Pattern 4: INSERT with host variables
# ──────────────────────────────────────────────────────────────────────────────
def test_insert():
    raw = "INSERT INTO audit_log (user_id, action, log_date) VALUES (:li_user, :ls_action, :ld_today)"
    parsed, tables, columns, meta = parse_pb_sql(raw)
    assert parsed is not None, "INSERT should parse"
    assert "audit_log" in tables
    assert meta["operation"] == "INSERT"
    assert meta["has_into"] is False


# ──────────────────────────────────────────────────────────────────────────────
# Pattern 5: UPDATE with WHERE host variable
# ──────────────────────────────────────────────────────────────────────────────
def test_update():
    raw = "UPDATE orders SET status = :ls_status, updated_by = :ls_user WHERE order_id = :li_id"
    parsed, tables, columns, meta = parse_pb_sql(raw)
    assert parsed is not None, "UPDATE should parse"
    assert "orders" in tables
    assert meta["operation"] == "UPDATE"


# ──────────────────────────────────────────────────────────────────────────────
# Pattern 6: DELETE with WHERE host variable
# ──────────────────────────────────────────────────────────────────────────────
def test_delete():
    raw = "DELETE FROM session_log WHERE session_id = :li_session AND expired = 1"
    parsed, tables, columns, meta = parse_pb_sql(raw)
    assert parsed is not None, "DELETE should parse"
    assert "session_log" in tables
    assert meta["operation"] == "DELETE"


# ──────────────────────────────────────────────────────────────────────────────
# Pattern 7: COMMIT USING SQLCA → rewritten to COMMIT
# ──────────────────────────────────────────────────────────────────────────────
def test_commit_using_rewrite():
    raw = "COMMIT USING SQLCA"
    standard = pb_sql_to_standard(raw)
    assert standard is not None
    assert standard.strip().upper() == "COMMIT"

    parsed, tables, columns, meta = parse_pb_sql(raw)
    assert meta["operation"] == "COMMIT"


# ──────────────────────────────────────────────────────────────────────────────
# Pattern 8: ROLLBACK USING SQLCA → rewritten to ROLLBACK
# ──────────────────────────────────────────────────────────────────────────────
def test_rollback_using_rewrite():
    raw = "ROLLBACK USING SQLCA"
    standard = pb_sql_to_standard(raw)
    assert standard is not None
    assert standard.strip().upper() == "ROLLBACK"

    parsed, tables, columns, meta = parse_pb_sql(raw)
    assert meta["operation"] == "ROLLBACK"


# ──────────────────────────────────────────────────────────────────────────────
# Pattern 9: DECLARE cursor FOR SELECT → rewritten to inner SELECT
# ──────────────────────────────────────────────────────────────────────────────
def test_declare_cursor_rewrite():
    raw = "DECLARE cur_order CURSOR FOR SELECT order_id, order_date FROM orders WHERE cust_id = :li_id"
    standard = pb_sql_to_standard(raw)
    assert standard is not None
    assert standard.strip().upper().startswith("SELECT"), (
        f"DECLARE...FOR SELECT should strip to inner SELECT, got: {standard!r}"
    )

    parsed, tables, columns, meta = parse_pb_sql(raw)
    assert "orders" in tables
    assert meta["has_cursor"] is True


# ──────────────────────────────────────────────────────────────────────────────
# Pattern 10: OPEN / FETCH / CLOSE / CONNECT → skipped, return None
# ──────────────────────────────────────────────────────────────────────────────
@pytest.mark.parametrize(
    "raw,expected_op",
    [
        ("OPEN cur_order", "OPEN"),
        ("FETCH cur_order INTO :li_id, :ld_date", "FETCH"),
        ("CLOSE cur_order", "CLOSE"),
        ("CONNECT USING SQLCA", "CONNECT"),
        ("DISCONNECT USING SQLCA", "DISCONNECT"),
        ("EXECUTE IMMEDIATE :ls_dynamic_sql", "EXECUTE"),
    ],
)
def test_skip_unstructured(raw, expected_op):
    parsed, tables, columns, meta = parse_pb_sql(raw)
    assert parsed == [], f"{expected_op} should return empty list (got: {parsed!r})"
    assert tables == []
    assert meta["operation"] == expected_op


# ──────────────────────────────────────────────────────────────────────────────
# Pattern 11: DECLARE ... DYNAMIC CURSOR FOR <prepared-stmt-id> → skipped
# (no inline SQL text to extract; differs from DECLARE ... CURSOR FOR SELECT)
# ──────────────────────────────────────────────────────────────────────────────
def test_skip_dynamic_cursor_declare():
    raw = "DECLARE cur DYNAMIC CURSOR FOR SQLSA;"
    parsed, tables, columns, meta = parse_pb_sql(raw)
    assert parsed == []
    assert tables == []
    assert meta["operation"] == "DECLARE"


# ──────────────────────────────────────────────────────────────────────────────
# Pattern 12: DECLARE ... PROCEDURE FOR <storedproc> (...) → skipped
# (stored-procedure declare; no inline SELECT to extract; Oracle/Sybase/Watcom
# param styles all reduce to the same unparseable shape)
# ──────────────────────────────────────────────────────────────────────────────
@pytest.mark.parametrize(
    "raw",
    [
        "declare update_contacts procedure for sp_contacts\n\t\t(:ls_action,\n\t\t:li_id);",
        "declare update_contacts procedure for sp_contacts\n\t\t@action = :ls_action,\n\t\t@contact_id = :li_id;",
        "declare update_contacts procedure for sp_contacts\n\t\taction = :ls_action,\n\t\tcontact_id = :li_id;",
    ],
)
def test_skip_procedure_declare(raw):
    assert pb_sql_to_standard(raw) is None, "should be skipped by _SKIP_RE, not handed to sqlglot"

    parsed, tables, columns, meta = parse_pb_sql(raw)
    assert parsed == []
    assert tables == []
    assert meta["operation"] == "DECLARE"


# ──────────────────────────────────────────────────────────────────────────────
# Pattern 13: genuinely malformed SQL → meta carries the sqlglot error message
# ──────────────────────────────────────────────────────────────────────────────
def test_parse_failure_captures_error_message():
    raw = "SELECT * FROM ("
    parsed, tables, columns, meta = parse_pb_sql(raw)
    assert parsed is None
    assert "error" in meta, "meta must carry the sqlglot failure message for genuine parse errors"
    assert meta["error"], "error message must not be empty"


def test_parse_failure_replaces_ansi_codes_with_plain_markers():
    """sqlglot embeds \\x1b[4m...\\x1b[0m underline codes around the offending
    token; the UI's Raw tab is not a terminal, so the raw escape bytes must
    not leak through — but the highlighted token is useful, so it's kept,
    wrapped in plain »...« markers instead of being discarded."""
    raw = "SELECT * FROM (("
    parsed, tables, columns, meta = parse_pb_sql(raw)
    assert parsed is None
    assert "error" in meta
    assert "\x1b" not in meta["error"], "raw ANSI escape byte must not leak into stored error message"


def test_using_transobject_clause_stripped_on_any_statement():
    """USING <transaction-object> is valid PB syntax on UPDATE/DELETE/SELECT/
    INSERT too, not just COMMIT/ROLLBACK — must not be reported as a parse
    failure."""
    raw = (
        "UPDATE t SET x = 1 WHERE (:foo is null or :foo = foo) "
        "and (:bar is null or :bar = bar) using sqlca ;"
    )
    parsed, tables, columns, meta = parse_pb_sql(raw)
    assert parsed is not None, meta.get("error")
    assert "error" not in meta


def test_join_using_column_list_not_clobbered():
    """USING (col) join syntax must survive the transaction-object strip."""
    raw = "SELECT * FROM a JOIN b USING (id);"
    parsed, tables, columns, meta = parse_pb_sql(raw)
    assert parsed is not None, meta.get("error")


def test_pb_style_line_comment_stripped():
    """PB embedded SQL may contain '//' line comments; sqlglot treats bare
    '//' as division and fails, so they must be stripped before parsing."""
    raw = "SELECT x FROM t // pb style comment\nWHERE y = 1;"
    parsed, tables, columns, meta = parse_pb_sql(raw)
    assert parsed is not None, meta.get("error")


def test_skip_unstructured_has_no_error_key():
    """Intentionally-skipped forms (OPEN/CLOSE/...) are not failures — no 'error' key."""
    parsed, tables, columns, meta = parse_pb_sql("OPEN cur_order")
    assert parsed == []
    assert "error" not in meta


def test_extract_tables_normalizes_to_lowercase():
    """Oracle table names are case-insensitive; extracted names must be
    lowercased so MYTABLE and mytable don't appear as separate entries."""
    _, tables, _, _ = parse_pb_sql("SELECT id FROM MYTABLE WHERE x = 1")
    assert "mytable" in tables
    assert "MYTABLE" not in tables


def test_extract_columns_normalizes_to_lowercase():
    """Oracle column names are case-insensitive; extracted names must be
    lowercased so COL1 and col1 don't appear as separate entries."""
    _, _, columns, _ = parse_pb_sql("SELECT MyCol, OTHER_COL FROM t WHERE x = 1")
    assert "mycol" in columns
    assert "other_col" in columns
    assert "MyCol" not in columns
    assert "OTHER_COL" not in columns


def test_core_sql_has_no_io_imports():
    """pb.lib.sql must not import duckdb, subprocess, or pathlib."""
    mod = importlib.import_module("pb.lib.sql")
    assert mod.__file__ is not None
    src = open(mod.__file__).read()
    for forbidden in ["import duckdb", "import subprocess", "from pathlib"]:
        assert forbidden not in src, f"pb/lib/sql.py must not contain {forbidden!r}"
