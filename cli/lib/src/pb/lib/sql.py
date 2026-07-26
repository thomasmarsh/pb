"""PowerBuilder SQL parser — wraps sqlglot with PB-specific pre-processing."""

from __future__ import annotations

import re
from dataclasses import asdict, dataclass

import sqlglot
from sqlglot import exp
from sqlglot.optimizer.scope import traverse_scope

# sqlglot embeds raw ANSI underline codes (\x1b[4m...\x1b[0m) around the
# offending token in ParseError messages, for terminal display. The Raw tab
# isn't a terminal, so the escape bytes render as literal "[4m...[0m" — but
# the highlighted token itself is useful, so swap the ANSI markers for plain
# »...« brackets rather than discarding the highlight entirely.
_ANSI_HIGHLIGHT_RE = re.compile(r"\x1b\[4m(.*?)\x1b\[0m")

# Statements with no parseable SQL structure — extract metadata only
_SKIP_RE = re.compile(
    r"^\s*(CONNECT|DISCONNECT|OPEN|CLOSE|FETCH|EXECUTE\s+(?:IMMEDIATE|PROCEDURE)"
    r"|DECLARE\s+\w+\s+DYNAMIC\s+CURSOR\s+FOR\s+\w+\s*;?\s*$"
    r"|DECLARE\s+\w+\s+PROCEDURE\s+FOR\s+\w+)",
    re.I,
)

# PB-specific rewrites applied in order before feeding to sqlglot.
# Each entry is (compiled_pattern, replacement).  Replacement may be a string
# or a callable (re.sub-compatible).
_REWRITES: list[tuple[re.Pattern, object]] = [
    # Strip PB's "// line comment" — not a standard SQL line-comment marker
    # (sqlglot reads bare "//" as division), so it must go before any other
    # rewrite that might be confused by trailing comment text.
    (re.compile(r"//[^\n]*"), ""),
    # Strip the PB transaction-object clause: COMMIT/ROLLBACK/SELECT/UPDATE/
    # DELETE/INSERT ... USING <transobject>. Not standard SQL. Negative
    # lookahead on "(" avoids clobbering real `JOIN ... USING (col)` syntax.
    (re.compile(r"\bUSING\s+\w+\b(?!\s*\()", re.I), ""),
    # Strip PB host-variable INTO clause: SELECT ... INTO :v1, :v2 FROM ...
    # INSERT INTO tablename is safe — table names don't start with ':'.
    (re.compile(r"\bINTO\b\s+:\w+(?:\s*,\s*:\w+)*", re.I), ""),
    # Strip DECLARE cursor wrapper; keep inner SELECT
    (
        re.compile(
            r"DECLARE\s+\w+\s+CURSOR\s+FOR\s*\(?(SELECT.*)\)?",
            re.I | re.S,
        ),
        lambda m: m.group(1),
    ),
]


def pb_sql_to_standard(sql_text: str) -> str | None:
    """Pre-process PB SQL into standard SQL. Returns None for unstructured forms."""
    if _SKIP_RE.match(sql_text.strip()):
        return None
    result = sql_text
    for pattern, repl in _REWRITES:
        result = pattern.sub(repl, result)
    return result


def extract_tables(ast) -> list[str]:
    return [t.name.lower() for t in ast.find_all(exp.Table) if t.name]


def extract_columns(ast) -> list[str]:
    return [c.name.lower() for c in ast.find_all(exp.Column) if c.name]


@dataclass(frozen=True)
class TableRef:
    """A table identifier, optionally schema/namespace-qualified. Namespace-
    aware sibling of `extract_tables`' flat, bare-name list (Plan 157 Phase
    4.5) -- walks `exp.Table` directly, independent of any column reference,
    so a column-less table touch (`SELECT COUNT(*) FROM t`, bare `DELETE
    FROM t`) still produces a table-level ref."""

    namespace: str | None
    table: str


def extract_table_refs(ast) -> list[TableRef]:
    seen: set[tuple[str | None, str]] = set()
    refs: list[TableRef] = []
    for t in ast.find_all(exp.Table):
        if not t.name:
            continue
        ns, table = _table_ident(t)
        if (ns, table) in seen:
            continue
        seen.add((ns, table))
        refs.append(TableRef(ns, table))
    return refs


@dataclass(frozen=True)
class ColumnRef:
    """A single column reference, scoped to the table it was actually read from
    or written to (unlike extract_columns' flat, table-less name list)."""

    namespace: str | None
    table: str | None
    column: str
    is_write: bool


@dataclass(frozen=True)
class RowFilter:
    """A shallow WHERE-clause predicate: `col = <literal>` or `col IN (...)`
    only. Anything else (arithmetic, subqueries, OR-trees) is out of scope —
    see Plan 148 Phase 1a-2's rider note."""

    namespace: str | None
    table: str | None
    column: str
    op: str  # "=" or "in"
    values: tuple[str, ...]


def _table_ident(table_expr: exp.Table) -> tuple[str | None, str]:
    ns = table_expr.db or None
    return (ns.lower() if ns else None, table_expr.name.lower())


def _resolve_unqualified_table(
    column_name: str,
    scope_tables: dict[str, tuple[str | None, str]],
    catalog: dict[str, list[str]] | None,
) -> tuple[str | None, str | None]:
    """Resolve an unqualified column to the one source table in scope that
    can own it. A single-table scope is unambiguous by construction; a
    multi-table (implicit-join) scope needs a column catalog to disambiguate
    — without one, returns (None, None) rather than guessing."""
    if len(scope_tables) == 1:
        return next(iter(scope_tables.values()))
    if catalog:
        candidates = {
            table
            for _ns, table in scope_tables.values()
            if column_name.lower() in {c.lower() for c in catalog.get(table, [])}
        }
        if len(candidates) == 1:
            table = next(iter(candidates))
            ns = next(ns for ns, t in scope_tables.values() if t == table)
            return ns, table
    return None, None


def _insert_column_refs(insert: exp.Insert) -> list[ColumnRef]:
    target = insert.this
    if isinstance(target, exp.Schema):
        table_expr, columns = target.this, target.expressions
    elif isinstance(target, exp.Table):
        table_expr, columns = target, []
    else:
        return []
    if not isinstance(table_expr, exp.Table):
        return []
    ns, table = _table_ident(table_expr)
    return [
        ColumnRef(ns, table, ident.name.lower(), True)
        for ident in columns
        if ident.name
    ]


def _update_column_refs(update: exp.Update) -> list[ColumnRef]:
    table_expr = update.this
    if not isinstance(table_expr, exp.Table):
        return []
    ns, table = _table_ident(table_expr)
    refs = [
        ColumnRef(ns, table, eq.this.name.lower(), True)
        for eq in update.expressions
        if isinstance(eq, exp.EQ) and isinstance(eq.this, exp.Column) and eq.this.name
    ]
    where = update.args.get("where")
    if where is not None:
        refs.extend(
            ColumnRef(ns, table, col.name.lower(), False)
            for col in where.find_all(exp.Column)
            if col.name
        )
    return refs


def extract_column_refs(ast, catalog: dict[str, list[str]] | None = None) -> list[ColumnRef]:
    """Qualify every column reference to its source table, per-SELECT-scope
    (so UNION branches and repeated aliases of the same table can't bleed
    into each other), and flag INSERT column-lists / UPDATE SET targets as
    writes.

    Uses sqlglot's scope walker (the same machinery its optimizer uses) so
    each SELECT/UNION branch gets its own alias->table map — an alias never
    leaks into a sibling branch's scope, and two aliases of the same table
    (e.g. a self-join) both resolve to that one real table name, not to
    their alias text.
    """
    refs: list[ColumnRef] = []

    for insert in ast.find_all(exp.Insert):
        refs.extend(_insert_column_refs(insert))
    for update in ast.find_all(exp.Update):
        refs.extend(_update_column_refs(update))

    try:
        scopes = traverse_scope(ast)
    except Exception:
        scopes = []

    for scope in scopes:
        if not isinstance(scope.expression, exp.Select):
            continue
        scope_tables: dict[str, tuple[str | None, str]] = {
            alias: _table_ident(source)
            for alias, source in scope.sources.items()
            if isinstance(source, exp.Table)
        }
        for col in scope.columns:
            name = col.name
            if not name:
                continue
            alias = col.table or None
            if alias and alias in scope_tables:
                ns, table = scope_tables[alias]
                refs.append(ColumnRef(ns, table, name.lower(), False))
            elif alias:
                # Qualifier doesn't resolve to a known FROM/JOIN source in
                # this scope (e.g. an outer-scope correlation) -- keep the
                # qualifier as written rather than silently dropping it.
                refs.append(ColumnRef(None, alias.lower(), name.lower(), False))
            else:
                ns, table = _resolve_unqualified_table(name, scope_tables, catalog)
                refs.append(ColumnRef(ns, table, name.lower(), False))

    return refs


def _literal_values(expr) -> tuple[str, ...] | None:
    if isinstance(expr, exp.Literal):
        return (str(expr.this),)
    return None


def extract_row_filters(ast) -> list[RowFilter]:
    """Extract literal-equality and literal-IN predicates from WHERE clauses:
    `col = <literal>` and `col IN (<literals>)` only. Arithmetic, subqueries,
    and OR-trees are out of scope (see Plan 148 Phase 1a-2's rider note)."""
    filters: list[RowFilter] = []
    for where in ast.find_all(exp.Where):
        for eq in where.find_all(exp.EQ):
            if isinstance(eq.this, exp.Column) and eq.this.name:
                values = _literal_values(eq.expression)
                if values is not None:
                    filters.append(RowFilter(None, eq.this.table or None, eq.this.name.lower(), "=", values))
        for in_expr in where.find_all(exp.In):
            if isinstance(in_expr.this, exp.Column) and in_expr.this.name:
                literals = [_literal_values(e) for e in in_expr.expressions]
                if literals and all(v is not None for v in literals):
                    values = tuple(v[0] for v in literals if v is not None)
                    filters.append(
                        RowFilter(None, in_expr.this.table or None, in_expr.this.name.lower(), "in", values)
                    )
    return filters


def parse_pb_sql(
    raw_sql: str,
    dialect: str = "oracle",
    catalog: dict[str, list[str]] | None = None,
) -> tuple[list[dict] | None, list[str], list[str], dict]:
    """Parse PB embedded SQL.

    Returns (parsed_dict, tables, columns, metadata). metadata's "column_refs",
    "row_filters", and "table_refs" keys carry the scope-aware extraction
    (list[dict], JSON-ready) alongside the legacy flat tables/columns lists.
    parsed_dict is [] for unstructured forms (cursors, dynamic SQL, connections).
    """
    operation = raw_sql.strip().split()[0].upper() if raw_sql.strip() else "UNKNOWN"
    meta = {
        "operation": operation,
        "has_into": "INTO :" in raw_sql.upper(),
        "has_cursor": "CURSOR" in raw_sql.upper(),
    }

    standard = pb_sql_to_standard(raw_sql)
    if standard is None:
        # Known unstructured form (EXECUTE IMMEDIATE, DECLARE ... DYNAMIC CURSOR, etc.)
        # — not a parse error, just structurally unparseable. Return empty tables/columns
        # with parse_ok=True so the caller doesn't report it as a SQL parse failure.
        return [], [], [], meta

    dialects = [dialect] if dialect == "oracle" else [dialect, "oracle"]
    last_error: Exception | None = None
    for d in dialects:
        try:
            ast = sqlglot.parse_one(standard, dialect=d, error_level=sqlglot.ErrorLevel.RAISE)
            tables = extract_tables(ast)
            columns = extract_columns(ast)
            meta["column_refs"] = [asdict(r) for r in extract_column_refs(ast, catalog)]
            meta["row_filters"] = [asdict(f) for f in extract_row_filters(ast)]
            meta["table_refs"] = [asdict(r) for r in extract_table_refs(ast)]
            return ast.dump(), tables, columns, meta
        except Exception as e:
            last_error = e
            continue

    if last_error is not None:
        meta["error"] = _ANSI_HIGHLIGHT_RE.sub(r"»\1«", str(last_error))
    return None, [], [], meta
