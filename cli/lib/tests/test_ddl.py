"""Tests for parse_ddl (Plan 148 Phase 1a-3).

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
    return parse_ddl(text, dialect="mysql")


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
