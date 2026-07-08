"""DDL catalog parsing — wraps sqlglot to extract a static schema catalog
(tables/columns, primary keys, foreign keys, check constraints) from a
CREATE TABLE / CREATE VIEW dump. A view is treated as a table from the
analysis perspective — its resolved column list lands in the same
Catalog.tables list, with no namespace/table distinction between the two —
since Sch-based analysis only cares about what a statement reads/writes, not
whether the underlying object is a physical table or a view. A view's
columns come from either its own explicit column list
(`CREATE VIEW v (a, b) AS ...`) or, more commonly, its underlying SELECT's
output columns (`named_selects`), expanding any `SELECT *` via sqlglot's
optimizer against the tables/views already known from this same DDL dump.
Because a view can select from another view, resolution runs as a
fixed-point loop over the deferred CREATE VIEW statements: each pass
resolves whatever it can and folds those columns back into the working
catalog so a later pass can resolve views that depend on them; a pass that
makes no progress means the rest depend on something outside this DDL file
(or sqlglot couldn't expand a star) and are left out of the catalog — no
column list is ever guessed.

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
from sqlglot.errors import ErrorLevel, TokenError
from sqlglot.optimizer.qualify import qualify

_CONSTRAINT_STATE_RE = re.compile(
    r"\bUSING\s+INDEX(\s+\"[^\"]+\"|\s+[A-Za-z_][\w$#]*)?\b"
    r"|\b(?:ENABLE|DISABLE)(?:\s+(?:VALIDATE|NOVALIDATE))?\b"
    r"|\b(?:VALIDATE|NOVALIDATE)\b",
    re.IGNORECASE,
)

_VIEW_EDITIONING_RE = re.compile(r"\b(?:NON)?EDITIONABLE\b", re.IGNORECASE)


def _strip_constraint_state(text: str) -> str:
    """Remove Oracle's constraint_state tail keywords (ENABLE/DISABLE/
    VALIDATE/NOVALIDATE/USING INDEX [name]) that sqlglot's grammar does not
    parse, in either CREATE TABLE or ALTER TABLE ADD CONSTRAINT context."""
    return _CONSTRAINT_STATE_RE.sub("", text)


def _strip_view_editioning_clause(text: str) -> str:
    """Remove Oracle's EDITIONABLE/NONEDITIONABLE view-editioning keyword
    (e.g. `CREATE OR REPLACE FORCE EDITIONABLE VIEW ...`). Same failure class
    as `_strip_constraint_state` — sqlglot's oracle dialect parses bare
    FORCE/NOFORCE fine but falls back to an opaque exp.Command for the whole
    statement once EDITIONABLE/NONEDITIONABLE appears."""
    return _VIEW_EDITIONING_RE.sub("", text)


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
    # One preview string per silently-lost statement, category-prefixed:
    # "[unparsed] <sql, truncated>" for an exp.Command fallback (also
    # counted in statements_skipped), "[unresolved view] <name>" for a
    # CREATE VIEW the fixed-point loop below never resolved (NOT counted in
    # statements_skipped — a distinct loss category with no counter of its
    # own until now).
    skipped_previews: tuple[str, ...] = ()


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


def _view_explicit_columns(view_target: exp.Table | exp.Schema) -> tuple[str, ...] | None:
    """Columns from CREATE VIEW v (col1, col2) AS ... — None if the view
    doesn't declare an explicit list (the common case; columns must then be
    inferred from the SELECT's own output instead)."""
    if isinstance(view_target, exp.Schema):
        cols = tuple(i.name.lower() for i in view_target.expressions if i.name)
        return cols or None
    return None


def _view_select_columns(
    query: exp.Query, known_columns: dict[str, object], dialect: str
) -> tuple[str, ...] | None:
    """Output column names inferred from a view's underlying query. Returns
    None if a `SELECT *` / `t.*` can't be expanded — the source table or view
    isn't in `known_columns` yet, which for a view-on-view chain means "not
    resolved on this pass, try again once known_columns has grown" rather
    than a permanent failure. qualify() itself never raises on a plain
    unresolvable star (it just leaves it unexpanded), but we still guard
    broadly since this module never raises on malformed DDL input."""
    if query.find(exp.Star) is None:
        names = tuple(n.lower() for n in query.named_selects if n and n != "*")
        return names or None
    try:
        qualified = qualify(query, schema=known_columns, dialect=dialect)
    except Exception:
        return None
    if qualified.find(exp.Star) is not None:
        return None
    names = tuple(n.lower() for n in qualified.named_selects if n and n != "*")
    return names or None


def _resolve_view(
    stmt: exp.Create,
    known_columns: dict[str, object],
    dialect: str,
    default_namespace: str | None,
) -> TableColumns | None:
    """Resolve one deferred CREATE VIEW statement to a TableColumns row, or
    None if its columns can't be determined yet (or ever) — the caller
    retries unresolved views across passes as `known_columns` grows from
    other newly-resolved views, and gives up once a full pass makes no
    progress."""
    view_target = stmt.this
    table_expr = view_target.this if isinstance(view_target, exp.Schema) else view_target
    if not isinstance(table_expr, exp.Table):
        return None
    ns, table_name = _table_ident(table_expr, default_namespace)

    columns = _view_explicit_columns(view_target)
    if columns is None:
        query = stmt.args.get("expression")
        if query is None:
            return None
        columns = _view_select_columns(query, known_columns, dialect)
    if columns is None:
        return None
    return TableColumns(namespace=ns, table=table_name, columns=columns)


def _unresolved_view_preview(stmt: exp.Create, dialect: str, default_namespace: str | None) -> str:
    """Best-effort name for a CREATE VIEW the fixed-point loop never
    resolved, for the "[unresolved view]" skipped_previews entry. Falls back
    to a truncated SQL preview if the view's own target isn't a plain
    identified table (should not happen for real DDL, but this module never
    raises on malformed input)."""
    view_target = stmt.this
    table_expr = view_target.this if isinstance(view_target, exp.Schema) else view_target
    if isinstance(table_expr, exp.Table):
        ns, name = _table_ident(table_expr, default_namespace)
        return f"{ns}.{name}" if ns else name
    return stmt.sql(dialect=dialect)[:200]


def _split_statements(text: str) -> list[str]:
    """Split DDL text into individual statements on top-level semicolons,
    tracking single/double-quoted string state and `--`/`/* */` comments so
    a semicolon inside a literal or comment doesn't split mid-statement.
    Used only as a fallback when sqlglot's own tokenizer can't process the
    whole file in one pass (a hard `TokenError`, distinct from the
    WARN-level per-statement `exp.Command` fallback `parse_ddl` normally
    relies on) — the goal is to isolate the one statement that broke
    tokenizing rather than lose the entire file. This is a best-effort
    recovery, not a real tokenizer: a genuinely malformed string literal
    (e.g. an unescaped apostrophe, the actual failure this exists to work
    around) has an inherently ambiguous end position, so this scanner can
    still misjudge where that *one* statement ends and swallow whatever
    comes after it into the same broken chunk — but everything strictly
    before the corruption still splits and parses correctly, which is
    always at least as good as the current all-or-nothing failure."""
    statements: list[str] = []
    buf: list[str] = []
    i = 0
    n = len(text)
    in_squote = in_dquote = False
    in_line_comment = in_block_comment = False
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_line_comment:
            buf.append(c)
            i += 1
            if c == "\n":
                in_line_comment = False
            continue
        if in_block_comment:
            buf.append(c)
            if c == "*" and nxt == "/":
                buf.append(nxt)
                i += 2
                in_block_comment = False
                continue
            i += 1
            continue
        if in_squote:
            buf.append(c)
            i += 1
            if c == "'":
                if nxt == "'":  # doubled '' escape stays inside the string
                    buf.append(nxt)
                    i += 1
                else:
                    in_squote = False
            continue
        if in_dquote:
            buf.append(c)
            i += 1
            if c == '"':
                in_dquote = False
            continue
        if c == "'":
            in_squote = True
            buf.append(c)
            i += 1
            continue
        if c == '"':
            in_dquote = True
            buf.append(c)
            i += 1
            continue
        if c == "-" and nxt == "-":
            in_line_comment = True
            buf.append(c)
            i += 1
            continue
        if c == "/" and nxt == "*":
            in_block_comment = True
            buf.append(c)
            i += 1
            continue
        if c == ";":
            stmt = "".join(buf).strip()
            if stmt:
                statements.append(stmt)
            buf = []
            i += 1
            continue
        buf.append(c)
        i += 1
    tail = "".join(buf).strip()
    if tail:
        statements.append(tail)
    return statements


def parse_ddl(
    text: str, dialect: str = "mysql", default_namespace: str | None = None
) -> tuple[Catalog, DdlStats]:
    """Parse a DDL dump into a Catalog. Never raises on malformed input —
    a statement sqlglot can't structurally parse (WARN error level) falls
    back to an inert exp.Command and is skipped, so one bad statement does
    not lose every other table in the file. `default_namespace` fills in
    the schema for a table (or FK reference) left unqualified in the DDL
    text, matching the common per-schema-dump export convention."""
    text = _strip_view_editioning_clause(_strip_constraint_state(text))

    skipped = 0
    tokenize_error_count = 0
    skipped_previews: list[str] = []
    try:
        statements = sqlglot.parse(text, dialect=dialect, error_level=ErrorLevel.WARN)
    except TokenError:
        # The whole file failed to tokenize (e.g. a malformed string
        # literal) -- fall back to a conservative semicolon-based split so
        # ONE bad statement doesn't lose every table in the file. See
        # _split_statements' own docstring for why this recovery is
        # best-effort, not guaranteed complete. Caught narrowly (TokenError
        # only, not bare Exception): a caller error like an unknown dialect
        # name (ValueError) must still propagate as a hard failure, not get
        # silently absorbed into per-chunk skipped_previews.
        statements = []
        for chunk in _split_statements(text):
            try:
                statements.extend(sqlglot.parse(chunk, dialect=dialect, error_level=ErrorLevel.WARN))
            except TokenError:
                tokenize_error_count += 1
                skipped_previews.append(f"[tokenize error] {chunk[:200]}")

    tables: list[TableColumns] = []
    primary_keys: list[TablePrimaryKey] = []
    foreign_keys: list[ForeignKey] = []
    checks: list[CheckConstraint] = []
    view_stmts: list[exp.Create] = []

    for stmt in statements:
        if isinstance(stmt, exp.Command):
            skipped += 1
            skipped_previews.append(f"[unparsed] {stmt.sql(dialect=dialect)[:200]}")
            continue

        if isinstance(stmt, exp.Create) and stmt.kind == "VIEW":
            view_stmts.append(stmt)

        elif isinstance(stmt, exp.Create) and stmt.kind == "TABLE":
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

    known_columns: dict[str, object] = {t.table: {c: "" for c in t.columns} for t in tables}
    remaining = view_stmts
    while remaining:
        resolved: list[TableColumns] = []
        still_remaining: list[exp.Create] = []
        for stmt in remaining:
            row = _resolve_view(stmt, known_columns, dialect, default_namespace)
            if row is None:
                still_remaining.append(stmt)
            else:
                resolved.append(row)
        if not resolved:
            break
        for row in resolved:
            tables.append(row)
            known_columns[row.table] = {c: "" for c in row.columns}
        remaining = still_remaining

    for stmt in remaining:
        skipped_previews.append(f"[unresolved view] {_unresolved_view_preview(stmt, dialect, default_namespace)}")

    stats = DdlStats(
        statements_total=len(statements) + tokenize_error_count,
        statements_parsed=len(statements) - skipped,
        statements_skipped=skipped + tokenize_error_count,
        skipped_previews=tuple(skipped_previews),
    )
    return Catalog(tables=tables, primary_keys=primary_keys, foreign_keys=foreign_keys, checks=checks), stats
