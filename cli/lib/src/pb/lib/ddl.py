"""DDL catalog parsing — wraps sqlglot to extract a static schema catalog
(tables/columns, primary keys, foreign keys) from a CREATE TABLE dump.

Plan 148 Phase 1a-3: openpay ships its own DDL
(example/openpay-0.1.1b/schema-0.1.1.sql) as ground truth — no live DB
needed. The parsed Catalog also feeds extract_column_refs' catalog= param
(Phase 1a-2) to disambiguate implicit-join columns.
"""

from __future__ import annotations

from dataclasses import dataclass

import sqlglot
from sqlglot import exp


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
class Catalog:
    tables: list[TableColumns]
    primary_keys: list[TablePrimaryKey]
    foreign_keys: list[ForeignKey]

    def to_qualify_dict(self) -> dict[str, list[str]]:
        """table_name -> [column, ...], for extract_column_refs' catalog= param."""
        return {t.table: list(t.columns) for t in self.tables}


def _table_ident(table_expr: exp.Table) -> tuple[str | None, str]:
    ns = table_expr.db or None
    return (ns.lower() if ns else None, table_expr.name.lower())


def _foreign_key(
    constraint_name: str | None,
    from_namespace: str | None,
    from_table: str,
    fk: exp.ForeignKey,
) -> ForeignKey | None:
    reference = fk.args.get("reference")
    if reference is None:
        return None
    ref_schema = reference.this
    ref_table = ref_schema.this if isinstance(ref_schema, exp.Schema) else ref_schema
    if not isinstance(ref_table, exp.Table):
        return None
    to_ns, to_table = _table_ident(ref_table)
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


def parse_ddl(text: str, dialect: str = "mysql") -> Catalog:
    """Parse a DDL dump into a Catalog. Raises on malformed input — callers
    that need a parse_ok/failure signal (e.g. the sql_worker bridge) catch
    at that layer, matching how parse_pb_sql's callers handle SQL errors."""
    statements = sqlglot.parse(text, dialect=dialect)

    tables: list[TableColumns] = []
    primary_keys: list[TablePrimaryKey] = []
    foreign_keys: list[ForeignKey] = []

    for stmt in statements:
        if not isinstance(stmt, exp.Create) or stmt.kind != "TABLE":
            continue
        schema = stmt.this
        table_expr = schema.this if isinstance(schema, exp.Schema) else schema
        if not isinstance(table_expr, exp.Table):
            continue
        ns, table_name = _table_ident(table_expr)

        columns = tuple(
            c.this.name.lower()
            for c in schema.expressions
            if isinstance(c, exp.ColumnDef) and c.this and c.this.name
        )
        tables.append(TableColumns(namespace=ns, table=table_name, columns=columns))

        for c in schema.expressions:
            if isinstance(c, exp.PrimaryKey):
                pk_cols = tuple(i.name.lower() for i in c.expressions if i.name)
                if pk_cols:
                    primary_keys.append(
                        TablePrimaryKey(namespace=ns, table=table_name, columns=pk_cols)
                    )
            elif isinstance(c, exp.ForeignKey):
                fk = _foreign_key(None, ns, table_name, c)
                if fk is not None:
                    foreign_keys.append(fk)
            elif isinstance(c, exp.Constraint):
                name = c.this.name if c.this else None
                for inner in c.expressions:
                    if isinstance(inner, exp.ForeignKey):
                        fk = _foreign_key(name, ns, table_name, inner)
                        if fk is not None:
                            foreign_keys.append(fk)

    return Catalog(tables=tables, primary_keys=primary_keys, foreign_keys=foreign_keys)
