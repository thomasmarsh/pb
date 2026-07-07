"""Unit tests for pb.api.services.schema (Plan 153 D1 + D2 + D4 + D6).

Uses the `schema_db_conn` fixture (DDL catalog + SQL bridge enabled) — the
plain `db_conn` fixture has neither and cannot exercise these tables.
"""

from __future__ import annotations

import duckdb
from pb.api.services.schema import (
    get_co_update_rituals,
    get_column_managers,
    get_column_usage,
    get_fk_graph,
    get_procedure_footprint,
)


def test_get_co_update_rituals_counts(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_co_update_rituals(schema_db_conn)
    # Re-verified 2026-07-07 against a freshly-rebuilt schema DB before
    # implementing (this session's own prerequisite, after the D4 spike
    # number turned out stale last session): 74 total `writes` legs produce
    # 45 column pairs with co-write support >= 2 (the default min_support).
    assert len(result["rituals"]) == 45
    top = result["rituals"][0]
    assert top["co_write_support"] == 3
    assert {top["column_a"]["column"], top["column_b"]["column"]} <= {"kodfinal", "kodypal", "kodxrisi"}
    assert top["column_a"]["table"] == "misth_final_ypal"


def test_get_co_update_rituals_top_pairs_are_misth_final_ypal(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_co_update_rituals(schema_db_conn)
    top_support_3 = [r for r in result["rituals"] if r["co_write_support"] == 3]
    assert len(top_support_3) == 3
    pairs = {frozenset((r["column_a"]["column"], r["column_b"]["column"])) for r in top_support_3}
    assert pairs == {
        frozenset({"kodfinal", "kodypal"}),
        frozenset({"kodfinal", "kodxrisi"}),
        frozenset({"kodxrisi", "kodypal"}),
    }
    for r in top_support_3:
        assert r["column_a"]["table"] == "misth_final_ypal"
        assert r["column_b"]["table"] == "misth_final_ypal"


def test_get_co_update_rituals_no_violations_in_corpus(schema_db_conn: duckdb.DuckDBPyConnection):
    # Real finding, not a placeholder: every statement in this 422-file
    # corpus that writes one column of an established ritual pair also
    # writes its partner — zero anomalies, unlike D1's original prediction
    # that violations would be common. Worth surfacing as-is rather than
    # assuming this list should be non-empty.
    result = get_co_update_rituals(schema_db_conn)
    assert sum(len(r["violations"]) for r in result["rituals"]) == 0


def test_get_co_update_rituals_min_support_threshold(schema_db_conn: duckdb.DuckDBPyConnection):
    # min_support=1 admits every co-occurring pair (76 support=1 + 45 at >=2).
    result = get_co_update_rituals(schema_db_conn, min_support=1)
    assert len(result["rituals"]) == 121
    result3 = get_co_update_rituals(schema_db_conn, min_support=3)
    assert len(result3["rituals"]) == 3


def test_get_fk_graph_counts(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_fk_graph(schema_db_conn)
    assert len(result["corroborated"]) == 47
    assert len(result["unenforced"]) == 5
    assert len(result["unused"]) == 36


def test_get_fk_graph_unenforced_edges_named(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_fk_graph(schema_db_conn)
    pairs = {
        (e["from_column"]["table"], e["from_column"]["column"], e["to_column"]["table"], e["to_column"]["column"])
        for e in result["unenforced"]
    }
    expected = {
        ("usrmembers", "koduser", "usrusers", "koduser"),
        ("usrgroupperm", "kodaction", "usractions", "kodaction"),
        ("usruserperm", "kodapp", "usrapps", "kodapp"),
        ("usrgroups", "kodgroup", "usrmembers", "kodgroup"),
        ("usractions", "kodapp", "usrapps", "kodapp"),
    }
    assert pairs == expected
    # every unenforced edge is dw_join-only — it must carry no ddl constraint
    # but at least one real DW source to link back to.
    for e in result["unenforced"]:
        assert e["constraint_name"] is None
        assert len(e["dw_sources"]) > 0


def test_get_fk_graph_unused_edges_have_no_dw_source(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_fk_graph(schema_db_conn)
    for e in result["unused"]:
        assert e["dw_sources"] == []


def test_get_column_usage_counts(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_column_usage(schema_db_conn)
    # Re-verified against a freshly-rebuilt schema DB (2026-07-07, twice, same
    # 4 columns both times) — corrects this plan's own earlier ad hoc spike,
    # which had reported 0 dead columns. Not a corpus-size artifact: these 4
    # are real, reproducible catalog-only columns with no reads or writes
    # anywhere in the 422-file corpus.
    assert len(result["dead"]) == 4
    assert len(result["write_only"]) == 0
    assert len(result["read_only"]) == 172
    assert len(result["read_write"]) == 53
    total = sum(len(v) for v in result.values())
    assert total == 229


def test_get_column_usage_dead_columns_named(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_column_usage(schema_db_conn)
    dead = {(c["table"], c["column"]) for c in result["dead"]}
    assert dead == {
        ("afxtable", "tablename"),
        ("afxtable", "tabledesc"),
        ("afxtablefields", "sorting"),
        ("misth_ypal", "kodtitlos"),
    }


def test_get_procedure_footprint_fn_perm(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_procedure_footprint(schema_db_conn, "fn_perm", "fn_perm")
    assert result is not None
    assert [s["line"] for s in result["statements"]] == [30, 41, 52, 63, 74]

    for stmt in result["statements"]:
        cols = {(c["table"], c["column"]) for c in stmt["columns"]}
        assert cols == {
            ("usrgroupperm", "kodgroup"),
            ("usrgroupperm", "kodaction"),
            ("usrmembers", "kodgroup"),
            ("usrmembers", "koduser"),
        }
        # Open Question 1: literal-only row-filter rider yields ~0 rows on
        # real embedded SQL (host-variable-bound predicates) — do not treat
        # an empty filters list as a bug.
        assert stmt["filters"] == []

    # the ambiguous addrec/editrec/delrec/openlist/openform action names
    # (table_name IS NULL) must be excluded from columns and reported
    # separately, one per statement line.
    assert [u["line"] for u in result["unresolved"]] == [30, 41, 52, 63, 74]
    assert {u["raw_name"] for u in result["unresolved"]} == {
        "addrec",
        "editrec",
        "delrec",
        "openlist",
        "openform",
    }


def test_get_procedure_footprint_not_found(schema_db_conn: duckdb.DuckDBPyConnection):
    assert get_procedure_footprint(schema_db_conn, "__nonexistent__", "__nope__") is None


def test_get_column_managers_includes_fn_perm(schema_db_conn: duckdb.DuckDBPyConnection):
    managers = get_column_managers(schema_db_conn, None, "usrgroupperm", "kodaction")
    sql_hits = [m for m in managers if m["kind"] == "sql"]
    assert any(m["object"] == "fn_perm" and m["proc_name"] == "fn_perm" for m in sql_hits)
    assert all(m["is_write"] is False for m in sql_hits)


def test_get_column_managers_unknown_column_is_empty(schema_db_conn: duckdb.DuckDBPyConnection):
    assert get_column_managers(schema_db_conn, None, "__nonexistent_table__", "__nonexistent_col__") == []
