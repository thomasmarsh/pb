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
`FOREIGN KEY (...) REFERENCES ... ENABLE` — plus a long, empirically-
discovered list of physical/storage attributes (TABLESPACE, PCTFREE,
STORAGE(...), ...), materialized-view refresh clauses (BUILD, REFRESH,
ENABLE/DISABLE QUERY REWRITE), and view-header clauses (EDITIONABLE,
BEQUEATH) sqlglot's oracle dialect doesn't model either. A single one of
these anywhere in a statement causes sqlglot to fall back to an opaque
`Command` for the *entire* statement (columns included).

`_filter_ddl_tokens` removes this fixed, Oracle-documented keyword
vocabulary at the TOKEN level — tokenize with sqlglot's own tokenizer,
drop the token runs matching known-unsupported clauses, hand the filtered
token list back to sqlglot's parser (which accepts a pre-tokenized list
directly, no re-serialization to text needed). This replaced an earlier
character-level regex implementation (2026-07-08 sessions) that
accumulated real fragility as the keyword list grew: hand-rolled quote/
comment/paren-depth tracking duplicated across multiple functions, a
backtracking `\b`-boundary bug that silently truncated matches for a whole
round before being caught, a "one level of nesting" cap on parenthesized
attribute lists that broke on real two-level-nested data, and an
open-ended non-greedy `REFRESH...AS` regex with no way to verify it
stopped at the right depth. Token-level filtering gets quote/comment
handling for free from the tokenizer (a keyword can never accidentally
match inside a string literal, since string tokens are a distinct type),
tracks nesting via an exact paren-depth counter over real paren tokens
(no depth cap), and can verify a clause's end boundary sits at the correct
depth before stopping. We deliberately still do not write a custom Oracle
DDL parser for the rest of the grammar — sqlglot already covers
CREATE TABLE/ALTER TABLE ADD CONSTRAINT structurally once this token
vocabulary is filtered, and Oracle DDL surface area (partitioning,
sequences, triggers, PL/SQL bodies, ...) is not otherwise a target of
this tool.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from sqlglot import Dialect, exp
from sqlglot.errors import ErrorLevel, TokenError
from sqlglot.optimizer.qualify import qualify
from sqlglot.tokenizer_core import Token, TokenType

# Oracle physical/storage attributes that can appear either attached to a
# constraint's backing index (`USING INDEX [name] TABLESPACE x ...`) or bare
# (a table's own tail, or a materialized view's attribute list) -- same
# vocabulary either way, found across several rounds of real-corpus triage
# (2026-07-08): none of it carries catalog-relevant information (columns/
# PK/FK/CHECK) regardless of where it appears, so it's always safe to drop.
_PHYSICAL_ATTR_KEYWORDS = frozenset({
    "TABLESPACE", "STORAGE", "PCTFREE", "PCTUSED", "INITRANS", "MAXTRANS",
    "LOGGING", "NOLOGGING", "COMPRESS", "NOCOMPRESS", "PARALLEL",
    "NOPARALLEL", "MONITORING", "NOMONITORING",
})

# Bare single-token clauses that are always safe to drop outright, found
# across several rounds of real-corpus triage (2026-07-08): table-level
# ROWDEPENDENCIES/NOROWDEPENDENCIES, virtual-column VIRTUAL, column-level
# VISIBLE/INVISIBLE (a distinct context from the USING INDEX ... VISIBLE
# case, which sqlglot already tolerates without stripping), and view-header
# EDITIONABLE/NONEDITIONABLE.
_BARE_DROP_KEYWORDS = frozenset({
    "ROWDEPENDENCIES", "NOROWDEPENDENCIES", "VIRTUAL", "VISIBLE",
    "INVISIBLE", "EDITIONABLE", "NONEDITIONABLE",
})

# Every keyword that starts one of this module's OTHER clause matchers.
# A bare "USING INDEX" with no real name (common at the materialized-view
# level, not attached to any constraint) can be immediately followed by one
# of these -- e.g. "USING INDEX\nREFRESH FORCE ON DEMAND" -- and without this
# check _match_using_index_name would misread REFRESH/BUILD/etc. as the
# index's name and swallow it, leaving the clause it belongs to with no
# anchor keyword left to match on. Found (2026-07-09) via a real
# materialized view shape where this exact adjacency broke REFRESH's own
# matcher after USING INDEX silently ate the word "REFRESH".
_CLAUSE_START_KEYWORDS = _PHYSICAL_ATTR_KEYWORDS | _BARE_DROP_KEYWORDS | frozenset({
    "REFRESH", "BUILD", "SEGMENT", "ORGANIZATION", "LOB", "BEQUEATH",
    "ENABLE", "DISABLE", "VALIDATE", "NOVALIDATE",
})


def _kw(token: Token, *names: str) -> bool:
    """True if token's text (case-insensitive) is one of `names`. Works for
    compound tokens sqlglot merges into one (e.g. PRIMARY KEY, START WITH)
    since this compares the token's own .text, not individual words."""
    return token.text.upper() in names


def _skip_paren(tokens: list[Token], open_idx: int) -> int:
    """Index just past the ')' matching tokens[open_idx] == L_PAREN, at
    arbitrary nesting depth (a plain counter over real paren tokens --
    unlike the regex era, there is no "how many levels deep" guess to get
    wrong). Returns len(tokens) if unbalanced (shouldn't happen for valid
    DDL; the caller just consumes to the end rather than crashing)."""
    depth = 0
    i = open_idx
    n = len(tokens)
    while i < n:
        if tokens[i].token_type == TokenType.L_PAREN:
            depth += 1
        elif tokens[i].token_type == TokenType.R_PAREN:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def _match_one_physical_attr(tokens: list[Token], i: int) -> int | None:
    """Match exactly one physical/storage attribute (keyword plus its
    value, if any) starting at tokens[i]. Returns the index past the match,
    or None if tokens[i] isn't the start of one."""
    if i >= len(tokens) or tokens[i].token_type != TokenType.VAR:
        return None
    word = tokens[i].text.upper()
    j = i + 1
    if word == "TABLESPACE":
        if j < len(tokens) and tokens[j].token_type in (TokenType.VAR, TokenType.IDENTIFIER):
            return j + 1
        return j
    if word == "STORAGE":
        if j < len(tokens) and tokens[j].token_type == TokenType.L_PAREN:
            return _skip_paren(tokens, j)
        return j
    if word in ("PCTFREE", "PCTUSED", "INITRANS", "MAXTRANS"):
        if j < len(tokens) and tokens[j].token_type == TokenType.NUMBER:
            return j + 1
        return j
    if word == "COMPUTE":
        if j < len(tokens) and _kw(tokens[j], "STATISTICS"):
            return j + 1
        return None  # bare "COMPUTE" isn't a recognized attribute; don't consume
    if word == "COMPRESS":
        if j < len(tokens) and tokens[j].token_type == TokenType.NUMBER:
            return j + 1
        return j
    if word == "PARALLEL":
        if j < len(tokens) and tokens[j].token_type == TokenType.NUMBER:
            return j + 1
        return j
    if word == "MONITORING":
        if j < len(tokens) and _kw(tokens[j], "USAGE"):
            return j + 1
        return j
    if word in ("LOGGING", "NOLOGGING", "NOCOMPRESS", "NOPARALLEL", "NOMONITORING"):
        return j
    return None


def _match_physical_attr_run(tokens: list[Token], i: int) -> int | None:
    """Match a repeated run of one-or-more physical attributes. Returns the
    index past the last one matched, or None if tokens[i] doesn't start
    one at all (distinguishes "matched zero" from "matched none" for
    callers that need to know whether anything was consumed)."""
    end = None
    j = i
    while True:
        nxt = _match_one_physical_attr(tokens, j)
        if nxt is None:
            break
        j = nxt
        end = j
    return end


def _match_using_index_name(tokens: list[Token], i: int) -> int | None:
    """Match an optional index name after USING INDEX: bare or quoted
    identifier, optionally schema-qualified (ns.name or "ns"."name").
    Quoted (IDENTIFIER-typed) names never collide with a clause keyword --
    quoting can't produce that ambiguity -- but a bare (VAR-typed) token
    must be checked against every OTHER clause's own starting keyword
    first: "USING INDEX TABLESPACE x" and a bare materialized-view-level
    "USING INDEX" immediately followed by "REFRESH ..." both have no name
    at all, and the following keyword would otherwise be misread as one
    (see _CLAUSE_START_KEYWORDS's own docstring for the real case this
    broke)."""
    if i >= len(tokens):
        return None
    t = tokens[i]
    if t.token_type == TokenType.IDENTIFIER:
        j = i + 1
    elif t.token_type == TokenType.VAR and t.text.upper() not in _CLAUSE_START_KEYWORDS:
        j = i + 1
    else:
        return None
    if (
        j + 1 < len(tokens)
        and tokens[j].token_type == TokenType.DOT
        and tokens[j + 1].token_type in (TokenType.VAR, TokenType.IDENTIFIER)
    ):
        j += 2
    return j


def _match_using_index_clause(tokens: list[Token], i: int) -> int | None:
    """USING INDEX [name | (column list)] [physical attributes]*, the
    dominant real-corpus cause of catalog-impacting DDL loss found across
    several rounds of triage (2026-07-08) -- a constraint's backing index
    almost always carries its own segment attributes in a real Oracle
    export. The explicit column-list form (`USING INDEX (col1, col2)`) is a
    distinct Oracle syntax from naming an existing/new index."""
    if i >= len(tokens) or tokens[i].token_type != TokenType.USING:
        return None
    j = i + 1
    if j >= len(tokens) or tokens[j].token_type != TokenType.INDEX:
        return None
    j += 1
    if j < len(tokens) and tokens[j].token_type == TokenType.L_PAREN:
        j = _skip_paren(tokens, j)
    else:
        name_end = _match_using_index_name(tokens, j)
        if name_end is not None:
            j = name_end
    attrs_end = _match_physical_attr_run(tokens, j)
    if attrs_end is not None:
        j = attrs_end
    return j


def _match_enable_disable_clause(tokens: list[Token], i: int) -> int | None:
    """ENABLE|DISABLE [VALIDATE|NOVALIDATE|QUERY REWRITE]. QUERY REWRITE is
    a materialized view's own clause (2026-07-08); without it, a bare
    ENABLE/DISABLE match alone would leave "QUERY REWRITE" behind."""
    if i >= len(tokens) or not _kw(tokens[i], "ENABLE", "DISABLE"):
        return None
    j = i + 1
    if j < len(tokens) and _kw(tokens[j], "VALIDATE", "NOVALIDATE"):
        return j + 1
    if j + 1 < len(tokens) and _kw(tokens[j], "QUERY") and _kw(tokens[j + 1], "REWRITE"):
        return j + 2
    return j


def _match_bare_validate_clause(tokens: list[Token], i: int) -> int | None:
    """VALIDATE|NOVALIDATE appearing without a preceding ENABLE/DISABLE."""
    if i < len(tokens) and _kw(tokens[i], "VALIDATE", "NOVALIDATE"):
        return i + 1
    return None


def _match_lob_store_as_clause(tokens: list[Token], i: int) -> int | None:
    """LOB (col[, col...]) STORE AS [SECUREFILE|BASICFILE] [(attributes)],
    where the attribute list can itself nest a STORAGE(...) clause -- the
    exact case the old regex's one-level nesting cap broke on; _skip_paren's
    real depth counter handles any nesting depth."""
    if i >= len(tokens) or not _kw(tokens[i], "LOB"):
        return None
    j = i + 1
    if j >= len(tokens) or tokens[j].token_type != TokenType.L_PAREN:
        return None
    j = _skip_paren(tokens, j)
    if j >= len(tokens) or not _kw(tokens[j], "STORE"):
        return None
    j += 1
    if j >= len(tokens) or tokens[j].token_type != TokenType.ALIAS:  # "AS"
        return None
    j += 1
    if j < len(tokens) and _kw(tokens[j], "SECUREFILE", "BASICFILE"):
        j += 1
    if j < len(tokens) and tokens[j].token_type == TokenType.L_PAREN:
        j = _skip_paren(tokens, j)
    return j


def _match_segment_creation_clause(tokens: list[Token], i: int) -> int | None:
    if i >= len(tokens) or not _kw(tokens[i], "SEGMENT"):
        return None
    j = i + 1
    if j >= len(tokens) or not _kw(tokens[j], "CREATION"):
        return None
    j += 1
    if j < len(tokens) and _kw(tokens[j], "IMMEDIATE", "DEFERRED"):
        return j + 1
    return None


def _match_build_clause(tokens: list[Token], i: int) -> int | None:
    if i >= len(tokens) or not _kw(tokens[i], "BUILD"):
        return None
    j = i + 1
    if j < len(tokens) and _kw(tokens[j], "IMMEDIATE", "DEFERRED"):
        return j + 1
    return None


def _match_refresh_clause(tokens: list[Token], i: int) -> int | None:
    """A materialized view's REFRESH clause: FAST/COMPLETE/FORCE,
    ON COMMIT/ON DEMAND, START WITH/NEXT date expressions, WITH PRIMARY
    KEY/WITH ROWID, USING ... TRUSTED CONSTRAINTS, FOR UPDATE -- too varied
    to enumerate keyword-by-keyword like physical attributes (2026-07-08),
    so this scans from REFRESH up to (not including) the view's own
    AS SELECT/AS (, verifying paren depth returns to 0 and no semicolon is
    crossed first -- the token-level equivalent of the old regex's
    non-greedy lookahead, but able to actually confirm the boundary is
    correct rather than hoping REFRESH's vocabulary never contains "AS"."""
    if i >= len(tokens) or not _kw(tokens[i], "REFRESH"):
        return None
    depth = 0
    j = i + 1
    n = len(tokens)
    while j < n:
        t = tokens[j]
        if t.token_type == TokenType.L_PAREN:
            depth += 1
        elif t.token_type == TokenType.R_PAREN:
            depth -= 1
        elif t.token_type == TokenType.SEMICOLON:
            return None  # ran into the next statement without finding AS
        elif t.token_type == TokenType.ALIAS and depth == 0:
            return j  # stop before the AS token itself
        j += 1
    return None  # no AS found before end of input


def _match_bequeath_clause(tokens: list[Token], i: int) -> int | None:
    if i >= len(tokens) or not _kw(tokens[i], "BEQUEATH"):
        return None
    j = i + 1
    if j < len(tokens) and _kw(tokens[j], "DEFINER"):
        return j + 1
    if j < len(tokens) and tokens[j].token_type == TokenType.CURRENT_USER:
        return j + 1
    return None


def _match_bare_drop_keyword(tokens: list[Token], i: int) -> int | None:
    if i < len(tokens) and tokens[i].token_type == TokenType.VAR and tokens[i].text.upper() in _BARE_DROP_KEYWORDS:
        return i + 1
    return None


def _match_organization_clause(tokens: list[Token], i: int) -> int | None:
    """ORGANIZATION HEAP|INDEX|EXTERNAL (attrs) -- table storage
    organization (HEAP is Oracle's own default, included for completeness
    since real exports write it explicitly). EXTERNAL's own attribute list
    is a single parenthesized group (TYPE/DEFAULT DIRECTORY/ACCESS
    PARAMETERS/LOCATION), handled the same way as every other attribute
    group via _skip_paren rather than enumerating its own grammar. Found
    (2026-07-09) via a real materialized view shape: the sole remaining
    blocker in that exact real-world statement."""
    if i >= len(tokens) or not _kw(tokens[i], "ORGANIZATION"):
        return None
    j = i + 1
    if j < len(tokens) and _kw(tokens[j], "HEAP", "INDEX"):
        return j + 1
    if j < len(tokens) and _kw(tokens[j], "EXTERNAL"):
        j += 1
        if j < len(tokens) and tokens[j].token_type == TokenType.L_PAREN:
            return _skip_paren(tokens, j)
        return j
    return None


# Tried in order at each token position; the first to match wins and its
# span is dropped. Order matters only where matchers could otherwise
# overlap (e.g. _match_using_index_clause must run before the bare
# _match_physical_attr_run would otherwise treat a USING-INDEX-attached
# TABLESPACE as if it were standalone) -- listed most-specific first.
_DDL_TOKEN_MATCHERS = (
    _match_using_index_clause,
    _match_enable_disable_clause,
    _match_bare_validate_clause,
    _match_lob_store_as_clause,
    _match_segment_creation_clause,
    _match_organization_clause,
    _match_build_clause,
    _match_refresh_clause,
    _match_bequeath_clause,
    _match_bare_drop_keyword,
    _match_physical_attr_run,
)


def _filter_ddl_tokens(tokens: list[Token]) -> list[Token]:
    """Drop every token run matching a known-unsupported Oracle DDL clause
    (constraint_state, physical/storage attributes, materialized-view
    refresh strategy, view-header clauses -- see module docstring), leaving
    everything else untouched. The filtered token list is handed directly
    to sqlglot's parser; no re-serialization to SQL text is needed."""
    out: list[Token] = []
    i = 0
    n = len(tokens)
    while i < n:
        matched_end = None
        for matcher in _DDL_TOKEN_MATCHERS:
            end = matcher(tokens, i)
            if end is not None and end > i:
                matched_end = end
                break
        if matched_end is not None:
            i = matched_end
            continue
        out.append(tokens[i])
        i += 1
    return out


def _tokenize_and_filter(dialect_instance: Dialect, text: str) -> list[Token]:
    """Tokenize `text` with `dialect_instance`'s own tokenizer and drop
    unsupported-clause token runs. May raise TokenError (e.g. a malformed
    string literal) -- callers handle that the same way they did for the
    old text-level pipeline."""
    return _filter_ddl_tokens(dialect_instance.tokenize(text))


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
    # True if _detect_hard_wrap_width found strong evidence the input was
    # hard-wrapped at a fixed column width (e.g. SQL*Plus SPOOL with
    # LINESIZE=80) and _dewrap_hard_wrapped_lines ran before any other
    # preprocessing. See that function's docstring — this is a real,
    # confirmed failure mode found via corpus triage (2026-07-08): a keyword
    # can be split across a physical line boundary mid-word.
    dewrapped: bool = False


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
    inferred from the SELECT's own output instead). A materialized view's
    column list can also mix in TABLE-shaped entries -- typed `ColumnDef`s
    plus inline CONSTRAINT/PrimaryKey/ForeignKey clauses -- rather than
    CREATE VIEW's plain name-only `Identifier` list; only ColumnDef/
    Identifier entries are real columns, so constraint entries are
    filtered out here and handled separately by the caller via
    _process_constraint. Confirmed via real-corpus testing (2026-07-08): an
    inline `CONSTRAINT pk1 PRIMARY KEY (...)` was otherwise producing the
    constraint's own name as a phantom column and silently dropping the
    primary key."""
    if isinstance(view_target, exp.Schema):
        cols = tuple(
            i.name.lower()
            for i in view_target.expressions
            if isinstance(i, (exp.ColumnDef, exp.Identifier)) and i.name
        )
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
    primary_keys: list[TablePrimaryKey],
    foreign_keys: list[ForeignKey],
    checks: list[CheckConstraint],
) -> TableColumns | None:
    """Resolve one deferred CREATE VIEW statement to a TableColumns row, or
    None if its columns can't be determined yet (or ever) — the caller
    retries unresolved views across passes as `known_columns` grows from
    other newly-resolved views, and gives up once a full pass makes no
    progress. Also extracts any inline PK/FK/CHECK constraints from a
    materialized view's TABLE-shaped column list (see
    _view_explicit_columns) into the same primary_keys/foreign_keys/checks
    lists CREATE TABLE populates — mutated in place, but only once
    resolution actually succeeds (not on every retry pass): this function
    gets called again for any view still unresolved after a pass, and
    processing constraints unconditionally would duplicate PK/FK/CHECK
    entries for any view that takes 2+ passes to resolve its columns."""
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

    if isinstance(view_target, exp.Schema):
        for c in view_target.expressions:
            if isinstance(c, (exp.Constraint, exp.PrimaryKey, exp.ForeignKey)):
                _process_constraint(
                    c, ns, table_name, default_namespace, dialect,
                    primary_keys, foreign_keys, checks,
                )

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


_HARD_WRAP_DETECTION_THRESHOLD = 0.15
# Below this many total lines (or this many lines at the max length), a
# concentration ratio isn't statistically meaningful -- a handful of short,
# normally-formatted lines can easily share a length by pure coincidence
# (found via a real regression: a 3-line test fixture had 1/3 lines share
# its max length, tripping the ratio threshold alone). Real hard-wrapped
# exports run to thousands of lines with thousands sharing the wrap width,
# so these floors don't affect genuine detection.
_HARD_WRAP_MIN_LINES = 20
_HARD_WRAP_MIN_LINES_AT_MAX = 5


def _detect_hard_wrap_width(text: str) -> int | None:
    """Detect whether `text` was hard-wrapped at a fixed column width by
    whatever tool exported or transferred it (e.g. SQL*Plus SPOOL with
    LINESIZE=80, the classic default) — such tools chop the raw output
    character stream at exactly N characters with no regard for token
    boundaries, unlike a text editor's word-aware soft wrap. This can split
    a keyword itself across a real newline (`ENABLE` becomes literally
    `EN\\nABLE` in the file), a failure no regex-based keyword strip can
    ever match since it expects each keyword as one contiguous token.
    Found via real-corpus triage (2026-07-08): a customer's DDL dump had
    max_line_length=80 accounting for 20.9% of all lines — far beyond
    anything coincidental. Returns the wrap width if the single most common
    (maximum) line length accounts for more than
    `_HARD_WRAP_DETECTION_THRESHOLD` of all lines (and both are above the
    minimum sample-size floors), else None (ordinary variable-length
    formatting, or too little text to tell; do not rewrap)."""
    lines = text.split("\n")
    if len(lines) < _HARD_WRAP_MIN_LINES:
        return None
    lengths: dict[int, int] = {}
    for line in lines:
        n = len(line)
        lengths[n] = lengths.get(n, 0) + 1
    max_len = max(lengths)
    if max_len == 0:
        return None
    if (
        lengths[max_len] >= _HARD_WRAP_MIN_LINES_AT_MAX
        and lengths[max_len] / len(lines) > _HARD_WRAP_DETECTION_THRESHOLD
    ):
        return max_len
    return None


def _dewrap_hard_wrapped_lines(text: str, wrap_width: int) -> str:
    """Reconstruct the true logical text from output hard-wrapped at
    `wrap_width`: a fixed-width wrap tool chops the character stream at
    exactly N characters with nothing skipped or inserted, so any physical
    line at *exactly* wrap_width chars is a continuation and must be joined
    to the next line with no separator; any shorter line (including a blank
    line) marks a genuine line break in the original, unwrapped text and is
    kept as a real newline."""
    lines = text.split("\n")
    out: list[str] = []
    buf = ""
    for line in lines:
        buf += line
        if len(line) == wrap_width:
            continue
        out.append(buf)
        buf = ""
    if buf:
        out.append(buf)
    return "\n".join(out)


def parse_ddl(
    text: str, dialect: str = "mysql", default_namespace: str | None = None
) -> tuple[Catalog, DdlStats]:
    """Parse a DDL dump into a Catalog. Never raises on malformed input —
    a statement sqlglot can't structurally parse (WARN error level) falls
    back to an inert exp.Command and is skipped, so one bad statement does
    not lose every other table in the file. `default_namespace` fills in
    the schema for a table (or FK reference) left unqualified in the DDL
    text, matching the common per-schema-dump export convention."""
    wrap_width = _detect_hard_wrap_width(text)
    dewrapped = wrap_width is not None
    if wrap_width is not None:
        text = _dewrap_hard_wrapped_lines(text, wrap_width)

    dialect_instance = Dialect.get_or_raise(dialect)

    skipped = 0
    tokenize_error_count = 0
    skipped_previews: list[str] = []
    try:
        filtered_tokens = _tokenize_and_filter(dialect_instance, text)
        statements = dialect_instance.parser(error_level=ErrorLevel.WARN).parse(filtered_tokens, text)
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
                chunk_tokens = _tokenize_and_filter(dialect_instance, chunk)
                statements.extend(dialect_instance.parser(error_level=ErrorLevel.WARN).parse(chunk_tokens, chunk))
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
            row = _resolve_view(stmt, known_columns, dialect, default_namespace, primary_keys, foreign_keys, checks)
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
        dewrapped=dewrapped,
    )
    return Catalog(tables=tables, primary_keys=primary_keys, foreign_keys=foreign_keys, checks=checks), stats
