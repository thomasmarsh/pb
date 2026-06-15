"""Unit tests for pb_cli/sql_parser.py — 10 representative PB SQL patterns.

Tests verify table/column extraction, metadata flags, and fallback behaviour.
All tests fail until sql_parser.py is created (Stage 2 gate).
"""
import pytest
from pb_cli.sql_parser import parse_pb_sql, pb_sql_to_standard


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
    raw = (
        "INSERT INTO audit_log (user_id, action, log_date) "
        "VALUES (:li_user, :ls_action, :ld_today)"
    )
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
@pytest.mark.parametrize("raw,expected_op", [
    ("OPEN cur_order",                                      "OPEN"),
    ("FETCH cur_order INTO :li_id, :ld_date",              "FETCH"),
    ("CLOSE cur_order",                                     "CLOSE"),
    ("CONNECT USING SQLCA",                                 "CONNECT"),
    ("DISCONNECT USING SQLCA",                              "DISCONNECT"),
    ("EXECUTE IMMEDIATE :ls_dynamic_sql",                   "EXECUTE"),
])
def test_skip_unstructured(raw, expected_op):
    parsed, tables, columns, meta = parse_pb_sql(raw)
    assert parsed is None, f"{expected_op} should not be parsed (got: {parsed!r})"
    assert tables == []
    assert meta["operation"] == expected_op
