"""DDL catalog parsing — wraps sqlglot to extract a static schema catalog
(tables/columns, primary keys, foreign keys, check constraints) from a
CREATE TABLE dump.

Plan 148 Phase 1a-3: openpay ships its own DDL
(example/openpay-0.1.1b/schema-0.1.1.sql) as ground truth — no live DB
needed. The parsed Catalog also feeds extract_column_refs' catalog= param
(Phase 1a-2) to disambiguate implicit-join columns.

Real Oracle DDL exports (e.g. from SQL Developer / exp/impdp) wrap almost
every constraint in a `constraint_state` tail sqlglot's grammar does not
model: `NOT NULL ENABLE`, `PRIMARY KEY (...) USING INDEX ENABLE`,
`FOREIGN KEY (...) REFERENCES ... ENABLE`. A single one of these anywhere
in a CREATE TABLE's body causes sqlglot to fall back to an opaque `Command`
for the *entire* statement (columns included) — so `_strip_constraint_state`
removes this fixed, Oracle-documented keyword vocabulary before parsing
rather than trying to teach sqlglot a grammar extension for it. We deliberately
do not write a custom Oracle DDL parser for the rest of the grammar — sqlglot
already covers CREATE TABLE/ALTER TABLE ADD CONSTRAINT structurally once this
tail is stripped, and Oracle DDL surface area (partitioning, storage/LOB
clauses, sequences, triggers, ...) is not otherwise a target of this tool.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

import sqlglot
from sqlglot import exp
from sqlglot.errors import ErrorLevel

_CONSTRAINT_STATE_RE = re.compile(
    r"\bUSING\s+INDEX(\s+\"[^\"]+\"|\s+[A-Za-z_][\w$#]*)?\b"
    r"|\b(?:ENABLE|DISABLE)(?:\s+(?:VALIDATE|NOVALIDATE))?\b"
    r"|\b(?:VALIDATE|NOVALIDATE)\b",
    re.IGNORECASE,
)


def _strip_constraint_state(text: str) -> str:
    """Remove Oracle's constraint_state tail keywords (ENABLE/DISABLE/
    VALIDATE/NOVALIDATE/USING INDEX [name]) that sqlglot's grammar does not
    parse, in either CREATE TABLE or ALTER TABLE ADD CONSTRAINT context."""
    return _CONSTRAINT_STATE_RE.sub("", text)


@dataclass(frozen=True)
class TableColumns:
    namespace: str | None
    table: str
    columns: tuple[str, ...]  # ordered by DDL column position


@dataclass(frozen=True)
class TablePrimaryKey:
    namespace: str | None
    table: str
    columns: tuple[str, ...]  # ordered; supports composite PK


@dataclass(frozen=True)
class ForeignKey:
    constraint_name: str | None  # None for an unnamed inline FK
    from_namespace: str | None
    from_table: str
    from_columns: tuple[str, ...]
    to_namespace: str | None
    to_table: str
    to_columns: tuple[str, ...]


@dataclass(frozen=True)
class CheckConstraint:
    constraint_name: str | None
    namespace: str | None
    table: str
    predicate: str  # sqlglot's normalized-SQL rendering of the CHECK predicate


@dataclass(frozen=True)
class Catalog:
    tables: list[TableColumns]
    primary_keys: list[TablePrimaryKey]
    foreign_keys: list[ForeignKey]
    checks: list[CheckConstraint] = field(default_factory=list)

    def to_qualify_dict(self) -> dict[str, list[str]]:
        """table_name -> [column, ...], for extract_column_refs' catalog= param."""
        return {t.table: list(t.columns) for t in self.tables}


@dataclass(frozen=True)
class DdlStats:
    statements_total: int
    statements_parsed: int
    statements_skipped: int  # fell back to an unstructured exp.Command


def _table_ident(table_expr: exp.Table, default_namespace: str | None = None) -> tuple[str | None, str]:
    ns = table_expr.db or default_namespace
    return (ns.lower() if ns else None, table_expr.name.lower())


def _foreign_key(
    constraint_name: str | None,
    from_namespace: str | None,
    from_table: str,
    fk: exp.ForeignKey,
    default_namespace: str | None,
) -> ForeignKey | None:
    reference = fk.args.get("reference")
    if reference is None:
        return None
    ref_schema = reference.this
    ref_table = ref_schema.this if isinstance(ref_schema, exp.Schema) else ref_schema
    if not isinstance(ref_table, exp.Table):
        return None
    to_ns, to_table = _table_ident(ref_table, default_namespace)
    to_columns = tuple(
        c.name.lower() for c in getattr(ref_schema, "expressions", []) if c.name
    )
    from_columns = tuple(c.name.lower() for c in fk.expressions if c.name)
    return ForeignKey(
        constraint_name=constraint_name,
        from_namespace=from_namespace,
        from_table=from_table,
        from_columns=from_columns,
        to_namespace=to_ns,
        to_table=to_table,
        to_columns=to_columns,
    )


def _process_constraint(
    c: exp.Constraint | exp.PrimaryKey | exp.ForeignKey,
    ns: str | None,
    table_name: str,
    default_namespace: str | None,
    dialect: str,
    primary_keys: list[TablePrimaryKey],
    foreign_keys: list[ForeignKey],
    checks: list[CheckConstraint],
) -> None:
    """Shared PK/FK/CHECK extraction for both an inline CREATE TABLE column
    list and an ALTER TABLE ADD CONSTRAINT action — both wrap the same
    PrimaryKey/ForeignKey/CheckColumnConstraint node shapes, named or not."""
    if isinstance(c, exp.PrimaryKey):
        pk_cols = tuple(i.name.lower() for i in c.expressions if i.name)
        if pk_cols:
            primary_keys.append(TablePrimaryKey(namespace=ns, table=table_name, columns=pk_cols))
    elif isinstance(c, exp.ForeignKey):
        fk = _foreign_key(None, ns, table_name, c, default_namespace)
        if fk is not None:
            foreign_keys.append(fk)
    elif isinstance(c, exp.Constraint):
        name = c.this.name if c.this else None
        for inner in c.expressions:
            if isinstance(inner, exp.PrimaryKey):
                pk_cols = tuple(i.name.lower() for i in inner.expressions if i.name)
                if pk_cols:
                    primary_keys.append(TablePrimaryKey(namespace=ns, table=table_name, columns=pk_cols))
            elif isinstance(inner, exp.ForeignKey):
                fk = _foreign_key(name, ns, table_name, inner, default_namespace)
                if fk is not None:
                    foreign_keys.append(fk)
            elif isinstance(inner, exp.CheckColumnConstraint):
                checks.append(
                    CheckConstraint(
                        constraint_name=name,
                        namespace=ns,
                        table=table_name,
                        predicate=inner.this.sql(dialect=dialect),
                    )
                )


def parse_ddl(
    text: str, dialect: str = "mysql", default_namespace: str | None = None
) -> tuple[Catalog, DdlStats]:
    """Parse a DDL dump into a Catalog. Never raises on malformed input —
    a statement sqlglot can't structurally parse (WARN error level) falls
    back to an inert exp.Command and is skipped, so one bad statement does
    not lose every other table in the file. `default_namespace` fills in
    the schema for a table (or FK reference) left unqualified in the DDL
    text, matching the common per-schema-dump export convention."""
    text = _strip_constraint_state(text)
    statements = sqlglot.parse(text, dialect=dialect, error_level=ErrorLevel.WARN)

    tables: list[TableColumns] = []
    primary_keys: list[TablePrimaryKey] = []
    foreign_keys: list[ForeignKey] = []
    checks: list[CheckConstraint] = []
    skipped = 0

    for stmt in statements:
        if isinstance(stmt, exp.Command):
            skipped += 1
            continue

        if isinstance(stmt, exp.Create) and stmt.kind == "TABLE":
            schema = stmt.this
            table_expr = schema.this if isinstance(schema, exp.Schema) else schema
            if not isinstance(table_expr, exp.Table):
                continue
            ns, table_name = _table_ident(table_expr, default_namespace)

            columns = tuple(
                c.this.name.lower()
                for c in schema.expressions
                if isinstance(c, exp.ColumnDef) and c.this and c.this.name
            )
            tables.append(TableColumns(namespace=ns, table=table_name, columns=columns))

            for c in schema.expressions:
                _process_constraint(
                    c, ns, table_name, default_namespace, dialect,
                    primary_keys, foreign_keys, checks,
                )

        elif isinstance(stmt, exp.Alter) and stmt.args.get("kind") == "TABLE":
            table_expr = stmt.this
            if not isinstance(table_expr, exp.Table):
                continue
            ns, table_name = _table_ident(table_expr, default_namespace)
            for action in stmt.args.get("actions", []):
                if not isinstance(action, exp.AddConstraint):
                    continue
                for c in action.expressions:
                    _process_constraint(
                        c, ns, table_name, default_namespace, dialect,
                        primary_keys, foreign_keys, checks,
                    )

    stats = DdlStats(
        statements_total=len(statements),
        statements_parsed=len(statements) - skipped,
        statements_skipped=skipped,
    )
    return Catalog(tables=tables, primary_keys=primary_keys, foreign_keys=foreign_keys, checks=checks), stats
