"""Tests for extract_column_refs / extract_row_filters (Plan 148 Phase 1a-2).

extract_tables/extract_columns (sql.py:61-66) return flat, unscoped lists —
harmless for single-table statements but losing all table<->column
association for any JOIN/UNION. These tests pin down the replacement:
extract_column_refs must attribute every column to its real source table
(not its alias), scoped per branch of a UNION.

Corpus fixtures below are real SQL pulled from the openpay corpus DB
(`sql_statements.raw_sql`) and the PowerBuilder-Example-extract DataWindow
retrieve text, not hand-invented shapes — see Plan 148's Corpus Verification
section for provenance.
"""

from __future__ import annotations

import sqlglot
from pb.lib.sql import (
    ColumnRef,
    RowFilter,
    extract_column_refs,
    extract_row_filters,
    pb_sql_to_standard,
)


def _parse(raw_sql: str):
    standard = pb_sql_to_standard(raw_sql)
    assert standard is not None, f"expected structured SQL, got skip form: {raw_sql!r}"
    return sqlglot.parse_one(standard, dialect="oracle", error_level=sqlglot.ErrorLevel.RAISE)


def _as_set(refs: list[ColumnRef]) -> set[tuple[str | None, str, bool]]:
    return {(r.table, r.column, r.is_write) for r in refs}


# ---------------------------------------------------------------------------
# Single-table statement: every column should already be qualified simply
# ---------------------------------------------------------------------------


def test_single_table_columns_qualified():
    raw = "SELECT cust_name, cust_email FROM customer WHERE cust_id = :li_id"
    ast = _parse(raw)
    refs = extract_column_refs(ast)
    assert _as_set(refs) == {
        ("customer", "cust_name", False),
        ("customer", "cust_email", False),
        ("customer", "cust_id", False),
    }


# ---------------------------------------------------------------------------
# Real corpus example: afxusers.pbl/fn_perm.srf (openpay), implicit comma-join
# across two tables, columns already qualified in source text
# ---------------------------------------------------------------------------

_FN_PERM_SQL = (
    "select sum(addrec) into :li_perm\n"
    "from   usrgroupperm, usrmembers\n"
    "where  usrgroupperm.kodgroup = usrmembers.kodgroup\n"
    "and\t usrmembers.koduser = :gl_koduser\n"
    "and\t usrgroupperm.kodaction = :as_action"
)


def test_join_columns_attributed_to_source_table():
    ast = _parse(_FN_PERM_SQL)
    refs = extract_column_refs(ast)
    got = _as_set(refs)
    # Every already-qualified column keeps its real source table -- this is
    # exactly the association extract_columns() throws away today.
    assert ("usrgroupperm", "kodgroup", False) in got
    assert ("usrgroupperm", "kodaction", False) in got
    assert ("usrmembers", "kodgroup", False) in got
    assert ("usrmembers", "koduser", False) in got


def test_ambiguous_implicit_join_resolved_only_with_catalog():
    ast = _parse(_FN_PERM_SQL)

    # addrec is unqualified in the source and appears in an implicit
    # (comma) join of two tables -- without a column catalog there is no
    # sound way to attribute it, so it must surface as table=None rather
    # than a guess.
    refs_no_catalog = extract_column_refs(ast)
    addrec_no_catalog = [r for r in refs_no_catalog if r.column == "addrec"]
    assert len(addrec_no_catalog) == 1
    assert addrec_no_catalog[0].table is None

    catalog = {
        "usrgroupperm": ["addrec", "editrec", "delrec", "kodgroup", "kodaction"],
        "usrmembers": ["koduser", "kodgroup"],
    }
    refs_with_catalog = extract_column_refs(ast, catalog=catalog)
    addrec_with_catalog = [r for r in refs_with_catalog if r.column == "addrec"]
    assert len(addrec_with_catalog) == 1
    assert addrec_with_catalog[0].table == "usrgroupperm"


# ---------------------------------------------------------------------------
# Real corpus example: pbexamor.pbl/d_example_report_detail.srd DataWindow
# retrieve text -- UNION of two branches, first branch aliases the same
# table twice (exam_xref_info_a / exam_xref_info_b). Both aliases must
# resolve to the real table name, and no branch's aliases may bleed into
# the other branch's scope.
# ---------------------------------------------------------------------------

_REPORT_DETAIL_UNION_SQL = (
    "SELECT DISTINCT exam_xref_list.refer, exam_xref_list.application, "
    "exam_xref_list.object, exam_xref_info_b.referenced_in "
    "FROM exam_xref_info exam_xref_info_a, exam_xref_info exam_xref_info_b, exam_xref_list "
    "WHERE ( exam_xref_info_b.object_ref = exam_xref_list.refer) "
    "and ( exam_xref_list.application = exam_xref_info_a.application ) "
    "and ( exam_xref_list.refer = exam_xref_info_a.referenced_in ) "
    "and ( exam_xref_list.application = :app) "
    "AND (exam_xref_list.object = :object) "
    "AND (exam_xref_info_b.event like '%inherit%') "
    "UNION "
    "SELECT DISTINCT exam_xref_list.refer, exam_xref_list.application, "
    "exam_xref_list.object, NULL "
    "FROM exam_xref_info exam_xref_info, exam_xref_list "
    "WHERE ( exam_xref_list.application = exam_xref_info.application ) "
    "and ( exam_xref_list.refer = exam_xref_info.referenced_in ) "
    "and ( exam_xref_list.application = :app) "
    "AND (exam_xref_list.object = :object) "
    "AND (exam_xref_list.refer NOT IN ("
    "SELECT object_ref FROM exam_xref_info WHERE (event like '%inherit%')))"
)


def test_union_branch_scoping_no_alias_bleed():
    ast = _parse(_REPORT_DETAIL_UNION_SQL)
    refs = extract_column_refs(ast)
    got = _as_set(refs)

    # Both aliases of exam_xref_info in branch 1 resolve to the real table
    # name -- not "exam_xref_info_a" / "exam_xref_info_b".
    assert ("exam_xref_info", "application", False) in got
    assert ("exam_xref_info", "referenced_in", False) in got
    assert ("exam_xref_info", "object_ref", False) in got
    assert ("exam_xref_info", "event", False) in got
    # No table object named after an alias should ever appear.
    assert not any(r.table in ("exam_xref_info_a", "exam_xref_info_b") for r in refs)

    assert ("exam_xref_list", "refer", False) in got
    assert ("exam_xref_list", "application", False) in got
    assert ("exam_xref_list", "object", False) in got


# ---------------------------------------------------------------------------
# Real corpus examples: openpay UPDATE ... SET and INSERT ... (cols) VALUES
# ---------------------------------------------------------------------------


def test_insert_and_update_set_columns_flagged_write():
    update_sql = "update afxkeygen set lastid = :ll_id where tblname = :as_tblname"
    update_ast = _parse(update_sql)
    update_refs = extract_column_refs(update_ast)
    assert ("afxkeygen", "lastid", True) in _as_set(update_refs)
    assert ("afxkeygen", "tblname", False) in _as_set(update_refs)

    insert_sql = (
        "insert into misth_final_ypal (kodfinal, kodypal, kodxrisi) "
        "values (:ll_kodfinal, :ll_kodypal, :gs_kodxrisi)"
    )
    insert_ast = _parse(insert_sql)
    insert_refs = extract_column_refs(insert_ast)
    assert _as_set(insert_refs) == {
        ("misth_final_ypal", "kodfinal", True),
        ("misth_final_ypal", "kodypal", True),
        ("misth_final_ypal", "kodxrisi", True),
    }


# ---------------------------------------------------------------------------
# Row-filter rider: literal equality and IN only
# ---------------------------------------------------------------------------


def test_row_filter_eq_and_in_extracted():
    raw = "SELECT balance FROM account WHERE status = 'Active' AND kind IN ('A', 'B')"
    ast = _parse(raw)
    filters = extract_row_filters(ast)
    got = {(f.table, f.column, f.op, f.values) for f in filters}
    assert (None, "status", "=", ("Active",)) in got or ("account", "status", "=", ("Active",)) in got
    assert (
        (None, "kind", "in", ("A", "B")) in got
        or ("account", "kind", "in", ("A", "B")) in got
    )
    assert all(isinstance(f, RowFilter) for f in filters)
