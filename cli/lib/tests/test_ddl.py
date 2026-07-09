"""Tests for parse_ddl (Plan 148 Phase 1a-3; Oracle constraint-state /
multi-schema hardening follow-up).

Ground truth: example/openpay-0.1.1b/schema-0.1.1.sql, a real MySQL dump
shipped with the openpay corpus — 36 CREATE TABLEs, 34 PRIMARY KEYs, 44 FK
REFERENCES. Verified directly against sqlglot before writing this file (see
Plan 148's Stage 1 proposal); these counts are not invented.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from pb.lib.ddl import parse_ddl

_SCHEMA_PATH = (
    Path(__file__).resolve().parents[3] / "example" / "openpay-0.1.1b" / "schema-0.1.1.sql"
)


@pytest.fixture(scope="module")
def openpay_catalog():
    text = _SCHEMA_PATH.read_text()
    catalog, _stats = parse_ddl(text, dialect="mysql")
    return catalog


def test_parse_ddl_openpay_table_count(openpay_catalog):
    assert len(openpay_catalog.tables) == 36


def test_parse_ddl_fk_afxfilterd_to_afxfilter(openpay_catalog):
    matches = [
        fk
        for fk in openpay_catalog.foreign_keys
        if fk.from_table == "afxfilterd" and fk.to_table == "afxfilter"
    ]
    assert len(matches) == 1
    fk = matches[0]
    assert fk.from_columns == ("kodfilter",)
    assert fk.to_columns == ("kodfilter",)


def test_parse_ddl_unique_key_when_no_pk(openpay_catalog):
    pk_tables = {pk.table for pk in openpay_catalog.primary_keys}
    assert "afxfilter" not in pk_tables
    assert len(openpay_catalog.primary_keys) == 34


# --- Oracle constraint-state / multi-schema hardening -----------------------

_ORACLE_TABLE = '''CREATE TABLE "CLIMS"."CLINICALACCESSION" (
  "ACC_ID" CHAR(13) NOT NULL ENABLE,
  "PAT_ID" CHAR(10),
  "STATUS" VARCHAR2(2),
  CONSTRAINT "PK_CLINICALACCESSION" PRIMARY KEY ("ACC_ID") USING INDEX ENABLE,
  CONSTRAINT "CK_STATUS" CHECK ("STATUS" IN ('T', 'TG')) ENABLE,
  CONSTRAINT "FK_CA_PAT" FOREIGN KEY ("PAT_ID") REFERENCES "CLIMS"."PATIENT" ("PAT_ID") ENABLE
)
'''


def test_parse_ddl_strips_enable_clause_and_parses_table():
    catalog, stats = parse_ddl(_ORACLE_TABLE, dialect="oracle")
    assert stats.statements_skipped == 0
    assert len(catalog.tables) == 1
    table = catalog.tables[0]
    assert table.namespace == "clims"
    assert table.table == "clinicalaccession"
    assert set(table.columns) == {"acc_id", "pat_id", "status"}


def test_parse_ddl_named_pk_constraint():
    catalog, _stats = parse_ddl(_ORACLE_TABLE, dialect="oracle")
    assert len(catalog.primary_keys) == 1
    pk = catalog.primary_keys[0]
    assert pk.table == "clinicalaccession"
    assert pk.columns == ("acc_id",)


def test_parse_ddl_check_constraint_captured():
    catalog, _stats = parse_ddl(_ORACLE_TABLE, dialect="oracle")
    assert len(catalog.checks) == 1
    check = catalog.checks[0]
    assert check.constraint_name == "CK_STATUS"
    assert "status" in check.predicate.lower()
    assert "'t'" in check.predicate.lower()


def test_parse_ddl_cross_schema_fk():
    catalog, _stats = parse_ddl(_ORACLE_TABLE, dialect="oracle")
    assert len(catalog.foreign_keys) == 1
    fk = catalog.foreign_keys[0]
    assert fk.from_table == "clinicalaccession"
    assert fk.to_namespace == "clims"
    assert fk.to_table == "patient"


def test_parse_ddl_alter_table_add_constraint_pk_and_fk():
    sql = '''
    CREATE TABLE "CLIMS"."CLINICALACCESSION" ("ACC_ID" CHAR(13), "PAT_ID" CHAR(10));
    ALTER TABLE "CLIMS"."CLINICALACCESSION" ADD CONSTRAINT "PK_CA" PRIMARY KEY ("ACC_ID") USING INDEX ENABLE;
    ALTER TABLE "CLIMS"."CLINICALACCESSION" ADD CONSTRAINT "FK_CA_PAT" FOREIGN KEY ("PAT_ID")
      REFERENCES "CLIMS"."PATIENT" ("PAT_ID") ENABLE;
    '''
    catalog, _stats = parse_ddl(sql, dialect="oracle")
    assert len(catalog.primary_keys) == 1
    assert catalog.primary_keys[0].columns == ("acc_id",)
    assert len(catalog.foreign_keys) == 1
    assert catalog.foreign_keys[0].to_table == "patient"


def test_parse_ddl_partial_failure_keeps_other_tables():
    sql = '''
    CREATE TABLE t1 (id NUMBER(10,2));
    CREATE UNIQUE INDEX "S"."UK_T2" ON "S"."T2" ("ID");
    CREATE TABLE t3 (id NUMBER(10,2));
    '''
    catalog, stats = parse_ddl(sql, dialect="oracle")
    assert {t.table for t in catalog.tables} == {"t1", "t3"}
    assert stats.statements_skipped == 1
    assert stats.statements_parsed == 2
    assert stats.statements_total == 3


_EDITIONABLE_VIEW = '''CREATE OR REPLACE FORCE EDITIONABLE VIEW "SCHEMA"."NAME" AS
SELECT "A", "B" FROM "SCHEMA"."T"
'''


def test_parse_ddl_strips_editionable_clause_and_parses_view():
    catalog, stats = parse_ddl(_EDITIONABLE_VIEW, dialect="oracle")
    assert stats.statements_skipped == 0
    assert len(catalog.tables) == 1
    table = catalog.tables[0]
    assert table.namespace == "schema"
    assert table.table == "name"
    assert set(table.columns) == {"a", "b"}


def test_parse_ddl_skipped_statement_preview_captured():
    sql = '''
    CREATE TABLE t1 (id NUMBER(10,2));
    CREATE UNIQUE INDEX "S"."UK_T2" ON "S"."T2" ("ID");
    '''
    _catalog, stats = parse_ddl(sql, dialect="oracle")
    assert len(stats.skipped_previews) == 1
    assert stats.skipped_previews[0].startswith("[unparsed] ")
    assert "UK_T2" in stats.skipped_previews[0]


def test_parse_ddl_unresolved_view_preview_captured():
    sql = '''
    CREATE TABLE t1 (id NUMBER);
    CREATE VIEW v_unknown AS SELECT * FROM some_other_table_not_in_this_dump;
    '''
    _catalog, stats = parse_ddl(sql, dialect="oracle")
    assert stats.statements_skipped == 0
    assert stats.skipped_previews == ("[unresolved view] v_unknown",)


# A single unescaped apostrophe makes the *whole file* unlexable to
# sqlglot's tokenizer (a hard TokenError, not the WARN-level per-statement
# exp.Command fallback) -- real-world trigger found live via a 4-schema
# Oracle DDL load. Confirmed empirically before writing these tests: without
# the _split_statements fallback in parse_ddl, this raises TokenError
# straight out of sqlglot.parse and every table in the file is lost.
_UNTERMINATED_QUOTE_STMT = "COMMENT ON COLUMN t2.name IS 'patient's identifier';"


def test_parse_ddl_tokenize_error_recovers_statements_before_the_break():
    sql = f'''
    CREATE TABLE t1 (id NUMBER);
    CREATE TABLE t3 (id NUMBER);
    {_UNTERMINATED_QUOTE_STMT}
    '''
    catalog, stats = parse_ddl(sql, dialect="oracle")
    assert {t.table for t in catalog.tables} == {"t1", "t3"}
    assert stats.statements_skipped == 1
    assert len(stats.skipped_previews) == 1
    assert stats.skipped_previews[0].startswith("[tokenize error] ")


def test_parse_ddl_tokenize_error_does_not_raise():
    sql = f'''
    CREATE TABLE t1 (id NUMBER);
    {_UNTERMINATED_QUOTE_STMT}
    '''
    # Must not raise -- this is the exact regression this fallback exists
    # to close (previously a bare TokenError out of sqlglot.parse).
    catalog, stats = parse_ddl(sql, dialect="oracle")
    assert {t.table for t in catalog.tables} == {"t1"}
    assert stats.statements_skipped >= 1


def test_parse_ddl_default_namespace_applied_to_unqualified_table():
    catalog, _stats = parse_ddl("CREATE TABLE clinicalaccession (acc_id NUMBER)", dialect="oracle", default_namespace="CLIMS")
    assert catalog.tables[0].namespace == "clims"


def test_parse_ddl_default_namespace_not_applied_when_already_qualified():
    catalog, _stats = parse_ddl(
        'CREATE TABLE "OTHER"."T" (id NUMBER)', dialect="oracle", default_namespace="CLIMS"
    )
    assert catalog.tables[0].namespace == "other"


def test_parse_ddl_fk_reference_falls_back_to_default_namespace():
    sql = 'CREATE TABLE t (id NUMBER, CONSTRAINT fk_t FOREIGN KEY (id) REFERENCES other_table (id))'
    catalog, _stats = parse_ddl(sql, dialect="oracle", default_namespace="CLIMS")
    assert catalog.foreign_keys[0].to_namespace == "clims"


# --- CREATE VIEW support -----------------------------------------------------

_ORDERS_CUSTOMERS_TABLES = '''
CREATE TABLE orders (id NUMBER, customer_id NUMBER, total NUMBER);
CREATE TABLE customers (id NUMBER, name VARCHAR2(100));
'''


def test_parse_ddl_view_with_explicit_column_list():
    sql = _ORDERS_CUSTOMERS_TABLES + '''
    CREATE VIEW v_orders (oid, cust, amt) AS SELECT id, customer_id, total FROM orders;
    '''
    catalog, stats = parse_ddl(sql, dialect="oracle")
    view = next(t for t in catalog.tables if t.table == "v_orders")
    assert view.columns == ("oid", "cust", "amt")
    assert stats.statements_skipped == 0


def test_parse_ddl_view_select_star_resolved_against_known_table():
    sql = _ORDERS_CUSTOMERS_TABLES + '''
    CREATE VIEW v_orders AS SELECT * FROM orders;
    '''
    catalog, _stats = parse_ddl(sql, dialect="oracle")
    view = next(t for t in catalog.tables if t.table == "v_orders")
    assert set(view.columns) == {"id", "customer_id", "total"}


def test_parse_ddl_view_select_star_with_join_resolved_against_two_tables():
    sql = _ORDERS_CUSTOMERS_TABLES + '''
    CREATE VIEW v_order_customers AS
      SELECT * FROM orders o JOIN customers c ON o.customer_id = c.id;
    '''
    catalog, _stats = parse_ddl(sql, dialect="oracle")
    view = next(t for t in catalog.tables if t.table == "v_order_customers")
    assert set(view.columns) == {"id", "customer_id", "total", "name"}


def test_parse_ddl_view_select_with_aliases_no_explicit_list():
    sql = _ORDERS_CUSTOMERS_TABLES + '''
    CREATE VIEW v_orders AS SELECT id AS order_id, total AS order_total FROM orders;
    '''
    catalog, _stats = parse_ddl(sql, dialect="oracle")
    view = next(t for t in catalog.tables if t.table == "v_orders")
    assert view.columns == ("order_id", "order_total")


def test_parse_ddl_view_selecting_from_another_view_multi_pass():
    sql = _ORDERS_CUSTOMERS_TABLES + '''
    CREATE VIEW v_orders AS SELECT * FROM orders;
    CREATE VIEW v_orders_wrapper AS SELECT * FROM v_orders;
    '''
    catalog, _stats = parse_ddl(sql, dialect="oracle")
    wrapper = next(t for t in catalog.tables if t.table == "v_orders_wrapper")
    assert set(wrapper.columns) == {"id", "customer_id", "total"}


def test_parse_ddl_view_select_star_unresolvable_table_produces_no_row():
    sql = '''
    CREATE TABLE t1 (id NUMBER);
    CREATE VIEW v_unknown AS SELECT * FROM some_other_table_not_in_this_dump;
    '''
    catalog, _stats = parse_ddl(sql, dialect="oracle")
    assert {t.table for t in catalog.tables} == {"t1"}


def test_parse_ddl_view_and_table_coexist_in_catalog():
    sql = _ORDERS_CUSTOMERS_TABLES + '''
    CREATE VIEW v_orders AS SELECT * FROM orders;
    '''
    catalog, _stats = parse_ddl(sql, dialect="oracle")
    assert {t.table for t in catalog.tables} == {"orders", "customers", "v_orders"}


# --- USING INDEX physical-attribute tail (found via real corpus triage: the
# common Oracle export shape attaches TABLESPACE/STORAGE/PCTFREE/etc. to a
# constraint's backing index, and the bare USING INDEX [name] stripping
# above leaves that tail behind as syntax garbage, still losing the whole
# statement) -----------------------------------------------------------------

_USING_INDEX_NAMED_TABLE = '''CREATE TABLE "CLIMS"."CLINICALACCESSION" (
  "ACC_ID" CHAR(13) NOT NULL ENABLE,
  CONSTRAINT "PK_CLINICALACCESSION" PRIMARY KEY ("ACC_ID")
    USING INDEX "CLIMS"."PK_CLINICALACCESSION_IDX"
    TABLESPACE "USERS"
    STORAGE (INITIAL 65536 NEXT 1048576 MINEXTENTS 1 MAXEXTENTS 2147483645 PCTINCREASE 0)
    ENABLE
)
'''


def test_parse_ddl_strips_using_index_named_with_physical_attrs():
    catalog, stats = parse_ddl(_USING_INDEX_NAMED_TABLE, dialect="oracle")
    assert stats.statements_skipped == 0
    assert len(catalog.primary_keys) == 1
    assert catalog.primary_keys[0].columns == ("acc_id",)


_USING_INDEX_UNNAMED_TABLE = '''CREATE TABLE "CLIMS"."PATIENT" (
  "PAT_ID" CHAR(10) NOT NULL ENABLE,
  CONSTRAINT "UK_PATIENT" UNIQUE ("PAT_ID")
    USING INDEX PCTFREE 10 INITRANS 2 MAXTRANS 255 LOGGING
    ENABLE
)
'''


def test_parse_ddl_strips_using_index_unnamed_with_physical_attrs():
    catalog, stats = parse_ddl(_USING_INDEX_UNNAMED_TABLE, dialect="oracle")
    assert stats.statements_skipped == 0
    assert len(catalog.tables) == 1
    assert set(catalog.tables[0].columns) == {"pat_id"}


def test_parse_ddl_alter_table_add_constraint_using_index_with_physical_attrs():
    sql = '''
    CREATE TABLE "CLIMS"."CLINICALACCESSION" ("ACC_ID" CHAR(13));
    ALTER TABLE "CLIMS"."CLINICALACCESSION"
      ADD CONSTRAINT "PK_CA" PRIMARY KEY ("ACC_ID")
      USING INDEX TABLESPACE "USERS" STORAGE (INITIAL 65536 NEXT 1048576) NOCOMPRESS
      ENABLE;
    '''
    catalog, stats = parse_ddl(sql, dialect="oracle")
    assert stats.statements_skipped == 0
    assert len(catalog.primary_keys) == 1
    assert catalog.primary_keys[0].columns == ("acc_id",)


# --- Second round of real-corpus-triage findings (2026-07-08): PARALLEL/
# MONITORING as USING INDEX attributes, an explicit column-list form of
# USING INDEX, table-level ROWDEPENDENCIES, virtual-column VIRTUAL, and
# view-header BEQUEATH DEFINER/CURRENT_USER -- each independently confirmed
# via synthetic reproduction to trip sqlglot's oracle dialect into the same
# whole-statement exp.Command fallback. -----------------------------------


def test_parse_ddl_using_index_with_parallel_and_monitoring():
    sql = 'CREATE TABLE T1 (A NUMBER, CONSTRAINT PK1 PRIMARY KEY (A) USING INDEX PARALLEL 4 MONITORING USAGE ENABLE)'
    catalog, stats = parse_ddl(sql, dialect="oracle")
    assert stats.statements_skipped == 0
    assert len(catalog.primary_keys) == 1


def test_parse_ddl_using_index_explicit_column_list():
    sql = 'CREATE TABLE T1 (A NUMBER, B NUMBER, CONSTRAINT UK1 UNIQUE (A) USING INDEX (A) ENABLE)'
    catalog, stats = parse_ddl(sql, dialect="oracle")
    assert stats.statements_skipped == 0
    assert set(catalog.tables[0].columns) == {"a", "b"}


def test_parse_ddl_strips_table_level_rowdependencies():
    sql = "CREATE TABLE T1 (A NUMBER) ROWDEPENDENCIES"
    catalog, stats = parse_ddl(sql, dialect="oracle")
    assert stats.statements_skipped == 0
    assert catalog.tables[0].columns == ("a",)


def test_parse_ddl_strips_virtual_column_keyword():
    sql = "CREATE TABLE T1 (A NUMBER, B NUMBER GENERATED ALWAYS AS (A + 1) VIRTUAL)"
    catalog, stats = parse_ddl(sql, dialect="oracle")
    assert stats.statements_skipped == 0
    assert set(catalog.tables[0].columns) == {"a", "b"}


def test_parse_ddl_strips_view_bequeath_clause():
    sql = "CREATE OR REPLACE FORCE EDITIONABLE VIEW V1 BEQUEATH DEFINER AS SELECT A FROM T1"
    catalog, stats = parse_ddl(sql, dialect="oracle")
    assert stats.statements_skipped == 0
    assert set(catalog.tables[0].columns) == {"a"}


# --- Third round of real-corpus-triage findings (2026-07-08): LOB storage
# clause and SEGMENT CREATION IMMEDIATE/DEFERRED, both table-level tail
# clauses confirmed via synthetic reproduction. (IDENTITY columns and bare
# table-level CACHE were also checked in this round and found to already
# parse fine -- their keyword hits in the triage histogram were red
# herrings, co-occurring with an unrelated failure in the same statement,
# not causal themselves; no fix needed for those.) ------------------------


def test_parse_ddl_strips_lob_store_as_clause():
    sql = "CREATE TABLE T1 (A NUMBER, B CLOB) LOB (B) STORE AS SECUREFILE (TABLESPACE USERS)"
    catalog, stats = parse_ddl(sql, dialect="oracle")
    assert stats.statements_skipped == 0
    assert set(catalog.tables[0].columns) == {"a", "b"}


def test_parse_ddl_strips_segment_creation_clause():
    sql = "CREATE TABLE T1 (A NUMBER) SEGMENT CREATION IMMEDIATE"
    catalog, stats = parse_ddl(sql, dialect="oracle")
    assert stats.statements_skipped == 0
    assert catalog.tables[0].columns == ("a",)


# --- Fourth round: found via the new bisection+redaction tool in
# scripts/diagnose_ddl_skips.py, which isolates the exact failing column/
# constraint definition and redacts identifiers before printing -- the
# redacted shape `<ID> NUMBER INVISIBLE` immediately identified this as a
# distinct context from the already-fixed USING INDEX ... VISIBLE case
# (2026-07-08): a bare column-level VISIBLE/INVISIBLE modifier still fails.


def test_parse_ddl_strips_column_level_invisible():
    sql = "CREATE TABLE T1 (A NUMBER, B NUMBER INVISIBLE)"
    catalog, stats = parse_ddl(sql, dialect="oracle")
    assert stats.statements_skipped == 0
    assert set(catalog.tables[0].columns) == {"a", "b"}


def test_parse_ddl_strips_column_level_visible():
    sql = "CREATE TABLE T1 (A NUMBER, B NUMBER VISIBLE)"
    catalog, stats = parse_ddl(sql, dialect="oracle")
    assert stats.statements_skipped == 0
    assert set(catalog.tables[0].columns) == {"a", "b"}


# --- Fifth round (2026-07-08): a real Oracle DDL dump can be hard-wrapped
# at a fixed column width by whatever tool exported or transferred it (e.g.
# SQL*Plus with LINESIZE=80, the classic default) -- physical lines get
# chopped at exactly N characters regardless of token boundaries, which can
# split a keyword itself across a real newline (`ENABLE` becomes literally
# `EN\nABLE` in the file). No regex-based keyword strip can ever match a
# keyword broken across a real line boundary. Confirmed via
# scripts/check_ddl_line_wrap.py on a real customer schema: max_line_length
# =80 accounted for 20.9% of all lines -- far above any coincidental
# clustering. `_detect_hard_wrap_width`/`_dewrap_hard_wrapped_lines`
# reconstruct the true logical text before any other preprocessing.


def _hard_wrap(text: str, width: int) -> str:
    """Test helper: simulate a fixed-width hard-wrap tool (e.g. SQL*Plus
    SPOOL with LINESIZE=width) by chopping text into width-character
    physical lines with no regard for token boundaries."""
    return "\n".join(text[i : i + width] for i in range(0, len(text), width))


def test_parse_ddl_dewraps_hard_wrapped_file():
    # Detection requires a statistically meaningful sample (>=20 lines,
    # >=5 at the max length) to avoid false-triggering on tiny inputs where
    # a couple of short lines can coincidentally share a length -- so this
    # fixture repeats enough statements to legitimately cross those floors,
    # matching how a real hard-wrapped export actually looks (thousands of
    # lines, not a handful).
    original = "".join(
        f"CREATE TABLE T{i} (A VARCHAR2(10), CONSTRAINT CK{i} CHECK (t_active_status IN ('Y', 'N')) ENABLE);"
        for i in range(20)
    )
    wrapped = _hard_wrap(original, 80)
    wrapped_lines = wrapped.split("\n")
    lines_at_80 = sum(1 for line in wrapped_lines if len(line) == 80)
    # Sanity check on the test fixture itself: confirm the wrap really did
    # split keywords mid-word and produced enough width-80 lines to clear
    # the detector's sample-size floors -- i.e. this reproduces the real
    # failure mode, not a degenerate case.
    assert len(wrapped_lines) >= 20
    assert lines_at_80 >= 5

    catalog, stats = parse_ddl(wrapped, dialect="oracle")
    assert stats.dewrapped is True
    assert stats.statements_skipped == 0
    assert {t.table for t in catalog.tables} == {f"t{i}" for i in range(20)}


def test_parse_ddl_does_not_dewrap_normally_formatted_file():
    # openpay's real DDL: naturally varying line lengths, well below the
    # detection threshold -- must NOT be touched by the dewrap heuristic.
    text = _SCHEMA_PATH.read_text()
    _catalog, stats = parse_ddl(text, dialect="mysql")
    assert stats.dewrapped is False


def test_parse_ddl_does_not_dewrap_small_multiline_input():
    # Regression: a small fixture (few lines) can have one line length
    # shared by 1/3 of all lines purely by coincidence, which used to trip
    # the ratio-only threshold and corrupt the text (this exact 2-statement,
    # 3-line shape broke test_parse_ddl_strips_editionable_clause_and_parses_view
    # by merging "AS" and "SELECT" into "ASSELECT" before the min-sample-size
    # floors were added).
    catalog, stats = parse_ddl(_EDITIONABLE_VIEW, dialect="oracle")
    assert stats.dewrapped is False
    assert stats.statements_skipped == 0
    assert set(catalog.tables[0].columns) == {"a", "b"}


# --- Sixth round (2026-07-08): after the hard-wrap fix eliminated the bulk
# of real-corpus loss, the remaining catalog-impacting failures exposed an
# architectural gap -- every physical/storage-attribute strip so far
# (_INDEX_PHYSICAL_ATTR) only fired when attached to a `USING INDEX` clause.
# A BARE table-level or materialized-view-level physical attribute (e.g.
# `CREATE TABLE t (...) TABLESPACE x`, with no USING INDEX/constraint
# involved at all) was never covered -- confirmed still failing even after
# every prior round. Also: a LOB store-as clause with a *nested* paren
# (e.g. `STORE AS SECUREFILE (TABLESPACE x STORAGE(...))`) broke the
# existing LOB regex's single-level `[^()]*` assumption.


def test_parse_ddl_strips_bare_table_level_tablespace():
    sql = "CREATE TABLE T1 (A NUMBER, B VARCHAR2(10)) TABLESPACE USERS"
    catalog, stats = parse_ddl(sql, dialect="oracle")
    assert stats.statements_skipped == 0
    assert set(catalog.tables[0].columns) == {"a", "b"}


def test_parse_ddl_strips_bare_materialized_view_physical_attrs():
    sql = (
        "CREATE MATERIALIZED VIEW MV1 PCTFREE 10 PCTUSED 40 INITRANS 1 MAXTRANS 255 "
        "LOGGING SEGMENT CREATION IMMEDIATE NOCOMPRESS AS SELECT A FROM T1"
    )
    catalog, stats = parse_ddl(sql, dialect="oracle")
    assert stats.statements_skipped == 0
    assert set(catalog.tables[0].columns) == {"a"}


def test_parse_ddl_strips_lob_store_as_with_nested_storage_paren():
    sql = "CREATE TABLE T1 (A NUMBER, B CLOB) LOB (B) STORE AS SECUREFILE (TABLESPACE USERS STORAGE(INITIAL 100K) LOGGING)"
    catalog, stats = parse_ddl(sql, dialect="oracle")
    assert stats.statements_skipped == 0
    assert set(catalog.tables[0].columns) == {"a", "b"}


# --- Seventh round (2026-07-08): the bare-physical-attrs fix above resolved
# the LABELING/harmless-vs-catalog-impacting confusion for materialized
# views, but did not move the real-corpus skip count at all -- the actual
# blocker turned out to be materialized-view-specific refresh-strategy
# clauses, unrelated to physical storage attributes, which essentially
# every real materialized view specifies: BUILD IMMEDIATE/DEFERRED, REFRESH
# FAST/COMPLETE/FORCE [ON COMMIT|ON DEMAND] [START WITH ...] [NEXT ...]
# [WITH PRIMARY KEY|WITH ROWID] [USING ...] [FOR UPDATE], and
# ENABLE/DISABLE QUERY REWRITE.


def test_parse_ddl_strips_materialized_view_build_clause():
    sql = "CREATE MATERIALIZED VIEW MV1 BUILD IMMEDIATE AS SELECT A FROM T1"
    catalog, stats = parse_ddl(sql, dialect="oracle")
    assert stats.statements_skipped == 0
    assert set(catalog.tables[0].columns) == {"a"}


def test_parse_ddl_strips_materialized_view_refresh_clause():
    sql = "CREATE MATERIALIZED VIEW MV1 BUILD IMMEDIATE REFRESH FAST ON COMMIT AS SELECT A FROM T1"
    catalog, stats = parse_ddl(sql, dialect="oracle")
    assert stats.statements_skipped == 0
    assert set(catalog.tables[0].columns) == {"a"}


def test_parse_ddl_strips_materialized_view_refresh_with_trusted_constraints():
    sql = "CREATE MATERIALIZED VIEW MV1 REFRESH FAST ON COMMIT USING TRUSTED CONSTRAINTS AS SELECT A FROM T1"
    catalog, stats = parse_ddl(sql, dialect="oracle")
    assert stats.statements_skipped == 0
    assert set(catalog.tables[0].columns) == {"a"}


def test_parse_ddl_strips_materialized_view_enable_query_rewrite():
    sql = "CREATE MATERIALIZED VIEW MV1 ENABLE QUERY REWRITE AS SELECT A FROM T1"
    catalog, stats = parse_ddl(sql, dialect="oracle")
    assert stats.statements_skipped == 0
    assert set(catalog.tables[0].columns) == {"a"}


def test_parse_ddl_materialized_view_inline_pk_not_treated_as_column():
    # Regression: found via real-corpus testing (2026-07-08). A materialized
    # view's explicit column list can mix ColumnDef entries with inline
    # CONSTRAINT/PrimaryKey clauses, unlike CREATE VIEW's plain name-only
    # list -- the constraint's own name ("pk1") was being treated as a
    # phantom column, and the primary key was silently dropped entirely.
    sql = '''
    CREATE MATERIALIZED VIEW MV1 (
      COL1 NUMBER, COL2 VARCHAR2(10),
      CONSTRAINT PK1 PRIMARY KEY (COL1) USING INDEX ENABLE
    )
    BUILD IMMEDIATE REFRESH FAST ON COMMIT
    AS SELECT COL1, COL2 FROM T1
    '''
    catalog, stats = parse_ddl(sql, dialect="oracle")
    assert stats.statements_skipped == 0
    assert set(catalog.tables[0].columns) == {"col1", "col2"}
    assert len(catalog.primary_keys) == 1
    assert catalog.primary_keys[0].columns == ("col1",)


def test_parse_ddl_materialized_view_column_list_resolves_across_passes_once():
    # Regression: a materialized view whose column resolution takes 2+
    # fixed-point passes (view-on-view chain) must not have its inline
    # constraints processed more than once -- _resolve_view is retried for
    # every unresolved view on every pass.
    sql = '''
    CREATE VIEW V1 AS SELECT A FROM T1;
    CREATE MATERIALIZED VIEW MV1 (
      A NUMBER,
      CONSTRAINT PK1 PRIMARY KEY (A)
    ) AS SELECT A FROM V1
    '''
    catalog, _stats = parse_ddl(sql, dialect="oracle")
    assert len(catalog.primary_keys) == 1
