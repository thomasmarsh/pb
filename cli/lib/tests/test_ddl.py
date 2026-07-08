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
