#
# Synthetic archive-schema DDL fixture (Plan 157 Phase 4/5) — NOT part of the
# real OpenPay export. Tagged under a second namespace (e.g. `--ddl
# OPENPAY_ARCHIVE:schema-archive.sql`, alongside `--ddl OPENPAY:schema-0.1.1.sql`
# and `--default-namespace OPENPAY`) to give the test corpus a genuine
# multi-schema shape: `misth_zpkrat` exists under both `OPENPAY` (the real
# schema, with real unqualified-SQL/DW-retrieve usage from the corpus's real
# PowerScript) and `OPENPAY_ARCHIVE` (this file, zero real usage — the
# `clinicalaccession`-in-3-schemas bug-report shape, minus the bug).
#
# Deliberately no FOREIGN KEY back to misth_zpxrisi (unlike the real table) —
# an archive snapshot dropping referential constraints is realistic, and it
# keeps this fixture self-contained (no need to duplicate misth_zpxrisi too).
#

CREATE TABLE misth_zpkrat (
  kodkrat varchar(20) NOT NULL default '',
  kodxrisi varchar(4) NOT NULL default '',
  desckrat varchar(50) NOT NULL default '',
  isforos int(11) default '0',
  isasf int(11) default '0',
  isautoforos int(11) default '0',
  archived_at date NOT NULL default '0000-00-00',
  PRIMARY KEY  (kodkrat,kodxrisi)
) ENGINE=InnoDB;
