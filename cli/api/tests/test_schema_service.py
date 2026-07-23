"""Unit tests for pb.api.services.schema (Plan 153 D1 + D2 + D4 + D6).

Uses the `schema_db_conn` fixture (DDL catalog + SQL bridge enabled) — the
plain `db_conn` fixture has neither and cannot exercise these tables.
"""

from __future__ import annotations

import duckdb
from pb.api.services.schema import (
    get_co_update_rituals,
    get_column_affinity,
    get_column_managers,
    get_column_usage,
    get_decomposition_candidates,
    get_fk_graph,
    get_footprint,
    get_window_table_lattice,
)


def test_get_co_update_rituals_mixed_namespace_sort():
    """Regression: ColumnKey's namespace is None for an unqualified column
    (e.g. a DW-retrieve leg) and a string for a schema-qualified one (e.g. a
    catalog-backed SQL leg) -- both can appear in the same corpus, and a bare
    `sorted()` over (namespace, table, column) tuples raises TypeError
    comparing None < str the moment one of each appears."""
    conn = duckdb.connect(":memory:")
    conn.execute(
        "CREATE TABLE schema_objects "
        "(object_key TEXT, kind TEXT, namespace TEXT, table_name TEXT, column_name TEXT, "
        "stmt_file TEXT, stmt_object TEXT, stmt_proc TEXT, stmt_line INTEGER)"
    )
    conn.execute("CREATE TABLE schema_morphisms (from_key TEXT, to_key TEXT, leg_kind TEXT, leg_source TEXT)")

    conn.execute(
        "INSERT INTO schema_objects VALUES "
        "('stmt1', 'stmt', NULL, NULL, NULL, 'f.srw', 'w_f', 'p1', 1), "
        "('stmt2', 'stmt', NULL, NULL, NULL, 'f.srw', 'w_f', 'p2', 2), "
        "('col_unqual', 'column', NULL, 't1', 'c1', NULL, NULL, NULL, NULL), "
        "('col_qual', 'column', 'clims', 't2', 'c2', NULL, NULL, NULL, NULL)"
    )
    conn.execute(
        "INSERT INTO schema_morphisms VALUES "
        "('stmt1', 'col_unqual', 'writes', 'sql_text'), "
        "('stmt1', 'col_qual', 'writes', 'sql_text'), "
        "('stmt2', 'col_unqual', 'writes', 'sql_text'), "
        "('stmt2', 'col_qual', 'writes', 'sql_text')"
    )

    result = get_co_update_rituals(conn, min_support=2)
    assert len(result["rituals"]) == 1
    assert result["rituals"][0]["co_write_support"] == 2


def test_get_co_update_rituals_counts(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_co_update_rituals(schema_db_conn)
    # Re-verified 2026-07-07 against a freshly-rebuilt schema DB before
    # implementing (this session's own prerequisite, after the D4 spike
    # number turned out stale last session): 74 total `writes` legs produce
    # 45 column pairs with co-write support >= 2 (the default min_support).
    assert len(result["rituals"]) == 45
    top = result["rituals"][0]
    assert top["co_write_support"] == 3
    assert {top["column_a"]["column"], top["column_b"]["column"]} <= {"kodfinal", "kodypal", "kodxrisi"}
    assert top["column_a"]["table"] == "misth_final_ypal"


def test_get_co_update_rituals_top_pairs_are_misth_final_ypal(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_co_update_rituals(schema_db_conn)
    top_support_3 = [r for r in result["rituals"] if r["co_write_support"] == 3]
    assert len(top_support_3) == 3
    pairs = {frozenset((r["column_a"]["column"], r["column_b"]["column"])) for r in top_support_3}
    assert pairs == {
        frozenset({"kodfinal", "kodypal"}),
        frozenset({"kodfinal", "kodxrisi"}),
        frozenset({"kodxrisi", "kodypal"}),
    }
    for r in top_support_3:
        assert r["column_a"]["table"] == "misth_final_ypal"
        assert r["column_b"]["table"] == "misth_final_ypal"


def test_get_co_update_rituals_no_violations_in_corpus(schema_db_conn: duckdb.DuckDBPyConnection):
    # Real finding, not a placeholder: every statement in this 422-file
    # corpus that writes one column of an established ritual pair also
    # writes its partner — zero anomalies, unlike D1's original prediction
    # that violations would be common. Worth surfacing as-is rather than
    # assuming this list should be non-empty.
    result = get_co_update_rituals(schema_db_conn)
    assert sum(len(r["violations"]) for r in result["rituals"]) == 0


def test_get_co_update_rituals_min_support_threshold(schema_db_conn: duckdb.DuckDBPyConnection):
    # min_support=1 admits every co-occurring pair (77 support=1 + 45 at >=2).
    # Was 121 (76 + 45) -- Plan 164 Phase C/E (2026-07-10, same day) resolved
    # w_misth_fylo_form.srw's runtime DW-alias SetItem call, adding a new
    # cat_footprint_columns-derived LegWrites edge and, with it, a new
    # cross-table co-write pair: misth_fylo_epidom.kodfylo <->
    # misth_fylo_krat.kodfylo (support=1). Re-verified directly against a
    # freshly-rebuilt schema DB (Plan 163 Phase 5 session) rather than
    # assumed from BACKLOG's diagnosis alone.
    result = get_co_update_rituals(schema_db_conn, min_support=1)
    assert len(result["rituals"]) == 122
    result3 = get_co_update_rituals(schema_db_conn, min_support=3)
    assert len(result3["rituals"]) == 3


def test_get_fk_graph_counts(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_fk_graph(schema_db_conn)
    assert len(result["corroborated"]) == 47
    assert len(result["unenforced"]) == 5
    assert len(result["unused"]) == 36


def test_get_fk_graph_unenforced_edges_named(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_fk_graph(schema_db_conn)
    pairs = {
        (e["from_column"]["table"], e["from_column"]["column"], e["to_column"]["table"], e["to_column"]["column"])
        for e in result["unenforced"]
    }
    expected = {
        ("usrmembers", "koduser", "usrusers", "koduser"),
        ("usrgroupperm", "kodaction", "usractions", "kodaction"),
        ("usruserperm", "kodapp", "usrapps", "kodapp"),
        ("usrgroups", "kodgroup", "usrmembers", "kodgroup"),
        ("usractions", "kodapp", "usrapps", "kodapp"),
    }
    assert pairs == expected
    # every unenforced edge is dw_join-only — it must carry no ddl constraint
    # but at least one real DW source to link back to.
    for e in result["unenforced"]:
        assert e["constraint_name"] is None
        assert len(e["dw_sources"]) > 0


def test_get_fk_graph_unused_edges_have_no_dw_source(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_fk_graph(schema_db_conn)
    for e in result["unused"]:
        assert e["dw_sources"] == []


def test_get_column_usage_counts(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_column_usage(schema_db_conn)
    # Re-verified against a freshly-rebuilt schema DB (2026-07-07, twice, same
    # 4 columns both times) — corrects this plan's own earlier ad hoc spike,
    # which had reported 0 dead columns. Not a corpus-size artifact: these 4
    # are real, reproducible catalog-only columns with no reads or writes
    # anywhere in the 422-file corpus.
    assert len(result["dead"]) == 4
    assert len(result["write_only"]) == 0
    # read_only 5 / read_write 220 (was 172 / 53): Plan 163 Phase 6 wired DW
    # update-table writes into schema_morphisms (get_column_usage
    # deliberately does NOT filter leg_source the way get_co_update_rituals
    # now does — "is this column ever written by anything" legitimately
    # includes a DataWindow's own generated Update(), unlike ritual/violation
    # detection's narrower "do independent code paths agree" question). Most
    # previously read_only DW-retrieve columns are also update=yes columns
    # of the same DW, so they correctly move into read_write.
    assert len(result["read_only"]) == 5
    assert len(result["read_write"]) == 220
    total = sum(len(v) for v in result.values())
    assert total == 229


def test_get_column_usage_dead_columns_named(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_column_usage(schema_db_conn)
    dead = {(c["table"], c["column"]) for c in result["dead"]}
    assert dead == {
        ("afxtable", "tablename"),
        ("afxtable", "tabledesc"),
        ("afxtablefields", "sorting"),
        ("misth_ypal", "kodtitlos"),
    }


def test_get_footprint_ps_object_fn_perm(schema_db_conn: duckdb.DuckDBPyConnection):
    """Plan 163 Phase 5: the unified, leg_source-carrying footprint over
    schema_objects/schema_morphisms, for the fn_perm/fn_perm PS case."""
    result = get_footprint(schema_db_conn, "fn_perm", "fn_perm")
    assert result is not None
    assert result["object"] == "fn_perm"
    assert result["proc_name"] == "fn_perm"
    assert result["kind"] == "sql"
    assert [s["line"] for s in result["statements"]] == [30, 41, 52, 63, 74]

    for stmt in result["statements"]:
        cols = {(leg["column"]["table"], leg["column"]["column"]) for leg in stmt["legs"]}
        assert cols == {
            ("usrgroupperm", "kodgroup"),
            ("usrgroupperm", "kodaction"),
            ("usrmembers", "kodgroup"),
            ("usrmembers", "koduser"),
        }
        for leg in stmt["legs"]:
            assert leg["leg_kind"] == "reads"
            assert leg["leg_source"] == "sql_text"


def test_get_footprint_dw_retrieve(schema_db_conn: duckdb.DuckDBPyConnection):
    """proc omitted -> DW retrieve lookup, keyed the same way a PS object is
    (schema_objects.stmt_object carries the DW's own name for a dw_retrieve
    row) -- confirmed real, non-guessed count against the openpay corpus."""
    result = get_footprint(schema_db_conn, "dw_misth_final_details_list")
    assert result is not None
    assert result["object"] == "dw_misth_final_details_list"
    assert result["proc_name"] is None
    assert result["kind"] == "dw_retrieve"
    assert len(result["statements"]) == 1
    legs = result["statements"][0]["legs"]
    # 14 (was 13 pre-Phase 6): the 13 retrieve legs plus one new WHERE-derived
    # LegReads leg (misth_final_ypal.kodxrisi, leg_source=dw_where) now that
    # Plan 163 Phase 6 wires DwFootprint's write/where legs into production.
    assert len(legs) == 14
    assert {leg["leg_kind"] for leg in legs} == {"retrieve", "reads"}
    cols = {(leg["column"]["table"], leg["column"]["column"]) for leg in legs}
    assert ("misth_final", "kodfinal") in cols
    assert ("misth_final_ypal", "kodxrisi") in cols


def test_get_footprint_dw_no_retrieve_sql(schema_db_conn: duckdb.DuckDBPyConnection):
    """Regression (Plan 163 Phase 6): dw_misth_final_search is a real,
    existing criteria-entry DataWindow with no retrieve SQL at all
    (dw_objects.retrieve_sql IS NULL for it in the real corpus) -- it has no
    schema_objects row, but it exists, so this must return an empty
    footprint (200), not None (404 -- which is reserved for an object that
    doesn't exist at all, see test_get_footprint_dw_not_found below)."""
    result = get_footprint(schema_db_conn, "dw_misth_final_search")
    assert result is not None
    assert result["object"] == "dw_misth_final_search"
    assert result["proc_name"] is None
    assert result["kind"] == "dw_retrieve"
    assert result["statements"] == []
    assert result["blast_radius"] == []


def test_get_footprint_blast_radius_fn_perm(schema_db_conn: duckdb.DuckDBPyConnection):
    """Blast radius is the union of decomposition_coslice reachability across
    every column the object's own footprint touches -- real corpus count,
    queried directly against a freshly-built schema DB before writing this
    assertion (not guessed): 19 distinct reachable statements from fn_perm's
    4 touched columns, including fn_perm's own 5 lines (other columns' reads
    legs point back at the same statements) plus DW retrieves/other PS call
    sites that touch usrgroupperm/usrmembers columns."""
    result = get_footprint(schema_db_conn, "fn_perm", "fn_perm")
    assert result is not None
    assert len(result["blast_radius"]) == 19


def test_get_footprint_ps_not_found(schema_db_conn: duckdb.DuckDBPyConnection):
    assert get_footprint(schema_db_conn, "__nonexistent__", "__nope__") is None


def test_get_footprint_dw_not_found(schema_db_conn: duckdb.DuckDBPyConnection):
    assert get_footprint(schema_db_conn, "__nonexistent_dw__") is None


def test_get_column_managers_includes_fn_perm(schema_db_conn: duckdb.DuckDBPyConnection):
    managers = get_column_managers(schema_db_conn, None, "usrgroupperm", "kodaction")
    sql_hits = [m for m in managers if m["kind"] == "sql"]
    assert any(m["object"] == "fn_perm" and m["proc_name"] == "fn_perm" for m in sql_hits)
    assert all(m["is_write"] is False for m in sql_hits)


def test_get_column_managers_unknown_column_is_empty(schema_db_conn: duckdb.DuckDBPyConnection):
    assert get_column_managers(schema_db_conn, None, "__nonexistent_table__", "__nonexistent_col__") == []


def test_get_column_affinity_unknown_table_is_none(schema_db_conn: duckdb.DuckDBPyConnection):
    assert get_column_affinity(schema_db_conn, None, "__nonexistent_table__") is None


def test_get_column_affinity_misth_ypal_counts(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_column_affinity(schema_db_conn, None, "misth_ypal")
    assert result is not None
    # Re-verified 2026-07-07 against a freshly-rebuilt schema DB before
    # implementing: misth_ypal (the widest real table) has 41 distinct
    # touched columns across 28 distinct statements/retrieves.
    assert len(result["columns"]) == 41
    assert len(result["co_access_matrix"]) == 41
    assert all(len(row) == 41 for row in result["co_access_matrix"])


def test_get_column_affinity_co_access_counts(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_column_affinity(schema_db_conn, None, "misth_ypal")
    cols = result["columns"]
    matrix = result["co_access_matrix"]

    def count(a: str, b: str) -> int:
        return matrix[cols.index(a)][cols.index(b)]

    # Real intersection counts (co-touching statements), verified against the
    # fresh rebuild -- not just Jaccard ratios.
    assert count("name", "surname") == 27
    assert count("fathername", "name") == 26
    assert count("kodypal", "kodxrisi") == 11
    assert count("bathmos", "klados") == 8
    # diagonal = the column's own support (n statements touching it)
    assert count("name", "name") == 27
    assert count("kodypal", "kodypal") == 12


def test_get_column_affinity_dendrogram_finds_named_blocks(schema_db_conn: duckdb.DuckDBPyConnection):
    # These are the three latent-entity blocks the plan's own spike predicted
    # "by eye" (Open Question 2) -- confirmed here as genuine high-similarity
    # merges in a real average-linkage dendrogram, distinguishable from a much
    # larger, lower-similarity blob of columns that merely share one broad
    # SELECT (real signal, but not a semantic normalization candidate).
    result = get_column_affinity(schema_db_conn, None, "misth_ypal")
    merges = {frozenset(m["members"]): m["similarity"] for m in result["dendrogram"]}

    assert frozenset({"name", "surname"}) in merges
    assert merges[frozenset({"name", "surname"})] == 1.0

    assert frozenset({"fathername", "name", "surname"}) in merges
    assert abs(merges[frozenset({"fathername", "name", "surname"})] - 0.963) < 0.001

    # 0.8462 (was 0.9167): shifted by Plan 163 Phase 6's DW-write/WHERE-read
    # leg wiring, which changed misth_ypal's real co-access counts -- a
    # genuine consequence of surfacing previously-invisible DW read/write
    # footprint, not a bug (re-verified directly against a freshly-rebuilt
    # schema DB, not guessed).
    assert frozenset({"kodypal", "kodxrisi"}) in merges
    assert abs(merges[frozenset({"kodypal", "kodxrisi"})] - 0.8462) < 0.001

    assert frozenset({"bathmos", "klados"}) in merges
    assert merges[frozenset({"bathmos", "klados"})] == 1.0

    assert frozenset({"bathmos", "klados", "klimakio"}) in merges
    assert abs(merges[frozenset({"bathmos", "klados", "klimakio"})] - 0.8889) < 0.001

    assert frozenset({"bathmos", "klados", "klimakio", "mitroo"}) in merges
    assert abs(merges[frozenset({"bathmos", "klados", "klimakio", "mitroo"})] - 0.7758) < 0.001


def test_get_column_affinity_leaf_order_groups_named_blocks(schema_db_conn: duckdb.DuckDBPyConnection):
    # The dendrogram's leaf order should place each named block's columns
    # contiguously, since that's what makes the "reordered heat matrix"
    # surface useful.
    result = get_column_affinity(schema_db_conn, None, "misth_ypal")
    cols = result["columns"]

    def indices(names: set[str]) -> list[int]:
        return sorted(cols.index(n) for n in names)

    for block in ({"name", "surname", "fathername"}, {"kodypal", "kodxrisi"}):
        idxs = indices(block)
        assert idxs == list(range(idxs[0], idxs[0] + len(idxs)))


def test_get_decomposition_candidates_unknown_table_is_none(schema_db_conn: duckdb.DuckDBPyConnection):
    assert get_decomposition_candidates(schema_db_conn, None, "__nonexistent_table__") is None


def test_get_decomposition_candidates_zero_evidence_still_reports_real_coslice(
    schema_db_conn: duckdb.DuckDBPyConnection,
):
    # misth_ypal has real D3 blocks (see test_get_column_affinity_dendrogram_
    # finds_named_blocks) but D1's rituals and D2's unenforced FKs never touch
    # this table in this corpus -- every candidate scores 0.0, not because the
    # coslice is empty (it isn't) but because there's no ritual/FK evidence
    # here. A real, honest finding, not a bug -- pinned as such rather than
    # skipped.
    result = get_decomposition_candidates(schema_db_conn, None, "misth_ypal", min_similarity=0.9)
    assert result is not None
    by_cols = {frozenset(c["columns"]): c for c in result["candidates"]}

    name_surname = by_cols[frozenset({"name", "surname"})]
    assert name_surname["ritual_support"] == 0
    assert name_surname["unenforced_fk_count"] == 0
    # coslice_size/len(paths) 65 (was 27): Plan 163 Phase 6's DW write/WHERE-
    # read legs expand real reachability from these columns -- a genuine
    # consequence of surfacing previously-invisible DW footprint, not a bug.
    assert name_surname["coslice_size"] == 65
    assert name_surname["score"] == 0.0
    assert len(name_surname["paths"]) == 65


def test_get_decomposition_candidates_misth_final_ypal_real_scores(schema_db_conn: duckdb.DuckDBPyConnection):
    # misth_final_ypal is the corpus's one table with real D1 (co-write
    # ritual) evidence -- confirmed here as a nonzero-score candidate, not
    # just a nonzero coslice.
    result = get_decomposition_candidates(schema_db_conn, None, "misth_final_ypal", min_similarity=0.7)
    by_cols = {frozenset(c["columns"]): c for c in result["candidates"]}

    # coslice_size 153 (was 120): same Plan 163 Phase 6 reachability
    # expansion as above (DW write/WHERE-read legs are real new edges).
    # ritual_support stays 9 -- get_co_update_rituals excludes DW-sourced
    # writes (see its own docstring), so this real PS-code co-write evidence
    # is unaffected by the write-leg wiring.
    triple = by_cols[frozenset({"kodfinal", "kodxrisi", "kodypal"})]
    assert triple["ritual_support"] == 9
    assert triple["unenforced_fk_count"] == 0
    assert triple["coslice_size"] == 153
    assert triple["score"] == 9 / 153

    # {kodfinal, kodxrisi} no longer clears min_similarity=0.7 on its own
    # (the same real co-access shift that moved misth_ypal's kodypal/kodxrisi
    # merge similarity, see test_get_column_affinity_dendrogram_finds_named_
    # blocks) -- {kodxrisi, kodypal} is the pair that does now.
    pair = by_cols[frozenset({"kodxrisi", "kodypal"})]
    assert pair["ritual_support"] == 3
    assert pair["coslice_size"] == 153
    assert pair["score"] == 3 / 153


def test_get_decomposition_candidates_paths_explain_fk_chained_reach(schema_db_conn: duckdb.DuckDBPyConnection):
    # Cross-check anchor: paths are first-class, not just a count -- a
    # 2-hop FK-chained target must show both legs, in order. Targets/legs are
    # structured `SchemaObjectRef` dicts (built by `_object_ref` from
    # decomposition_coslice's schema_objects join-back columns), not
    # formatted strings -- every field needed to navigate to the real
    # table/procedure/DataWindow (namespace/table/column, or
    # object/proc_name/line, or dw_name) is recovered, dropping only the
    # absolute pb-extract file path from display concerns (it's still
    # present under "file" for completeness).
    result = get_decomposition_candidates(schema_db_conn, None, "misth_final_ypal", min_similarity=0.7)
    triple = next(c for c in result["candidates"] if set(c["columns"]) == {"kodfinal", "kodxrisi", "kodypal"})

    fk_chained = next(p for p in triple["paths"] if p["target"].get("dw_name") == "dw_misth_final_form")
    assert fk_chained["target"]["kind"] == "dw_retrieve"
    assert fk_chained["direction"] == "backward"
    assert len(fk_chained["legs"]) == 2

    # leg_kind "writes" (was "retrieve"): dw_misth_final_form is an editable
    # form whose own update=yes columns now include kodfinal (Plan 163 Phase
    # 6's DW-write wiring) -- the coslice traversal's adjacency now finds
    # this leg via the new writes edge between the same two objects rather
    # than the pre-existing retrieve edge (both are real; this is which one
    # the BFS discovers first, deterministic given allLegs' fixed fold order).
    leg0 = fk_chained["legs"][0]
    assert leg0["from_object"] == {"kind": "dw_retrieve", "file": leg0["from_object"]["file"], "dw_name": "dw_misth_final_form"}
    assert leg0["to_object"] == {"kind": "column", "namespace": None, "table": "misth_final", "column": "kodfinal"}
    assert leg0["leg_kind"] == "writes"

    leg1 = fk_chained["legs"][1]
    assert leg1["from_object"] == {"kind": "column", "namespace": None, "table": "misth_final", "column": "kodfinal"}
    assert leg1["to_object"] == {"kind": "column", "namespace": None, "table": "misth_final_ypal", "column": "kodfinal"}
    assert leg1["leg_kind"] == "fk"


def test_object_ref_recovers_structured_fields():
    """`_object_ref` reads the schema_objects join-back columns
    `decomposition_coslice` carries (Plan 198 Phase F) instead of
    string-parsing the encoded `schObjectKey` -- same output shapes
    `_parse_object_key` used to produce."""
    from pb.api.services.schema import _object_ref

    dw_row = {"p_kind": "dw_retrieve", "p_stmt_file": "/tmp/pb-extract-abc123/final.pbl/dw_x.srd", "p_stmt_object": "dw_x"}
    assert _object_ref(dw_row, "p_", "stmt:dw:...") == {
        "kind": "dw_retrieve",
        "file": "/tmp/pb-extract-abc123/final.pbl/dw_x.srd",
        "dw_name": "dw_x",
    }

    sql_row = {
        "p_kind": "stmt",
        "p_stmt_file": "/tmp/pb-extract-abc123/final.pbl/n_svc.srw",
        "p_stmt_object": "n_svc",
        "p_stmt_proc": "of_process",
        "p_stmt_line": 42,
    }
    assert _object_ref(sql_row, "p_", "stmt:sql:...") == {
        "kind": "sql",
        "file": "/tmp/pb-extract-abc123/final.pbl/n_svc.srw",
        "object": "n_svc",
        "proc_name": "of_process",
        "line": 42,
    }

    unqual_col_row = {"p_kind": "column", "p_namespace": None, "p_table_name": "misth_final", "p_column_name": "kodfinal"}
    assert _object_ref(unqual_col_row, "p_", "col:...") == {
        "kind": "column",
        "namespace": None,
        "table": "misth_final",
        "column": "kodfinal",
    }

    qual_col_row = {"p_kind": "column", "p_namespace": "myns", "p_table_name": "misth_final", "p_column_name": "kodfinal"}
    assert _object_ref(qual_col_row, "p_", "col:...") == {
        "kind": "column",
        "namespace": "myns",
        "table": "misth_final",
        "column": "kodfinal",
    }

    no_match_row = {"p_kind": None}
    assert _object_ref(no_match_row, "p_", "col:orphan.key") == {
        "kind": "unknown",
        "file": "col:orphan.key",
    }


def test_get_decomposition_candidates_min_similarity_filters_low_blocks(
    schema_db_conn: duckdb.DuckDBPyConnection,
):
    loose = get_decomposition_candidates(schema_db_conn, None, "misth_ypal", min_similarity=0.0)
    strict = get_decomposition_candidates(schema_db_conn, None, "misth_ypal", min_similarity=0.95)
    assert len(strict["candidates"]) < len(loose["candidates"])
    assert all(c["similarity"] >= 0.95 for c in strict["candidates"])


def test_get_decomposition_candidates_includes_table_wide_affinity_overview(
    schema_db_conn: duckdb.DuckDBPyConnection,
):
    # Consolidation (2026-07-09): the standalone Column Affinity panel folds
    # into this one -- the response now carries the same table-wide heat
    # matrix + dendrogram get_column_affinity returns on its own, so the UI
    # has one fetch instead of two.
    result = get_decomposition_candidates(schema_db_conn, None, "misth_final_ypal", min_similarity=0.7)
    affinity = get_column_affinity(schema_db_conn, None, "misth_final_ypal")
    assert result["affinity"] == {
        "columns": affinity["columns"],
        "co_access_matrix": affinity["co_access_matrix"],
        "dendrogram": affinity["dendrogram"],
    }


def test_get_decomposition_candidates_ritual_pairs_empty_when_corpus_has_no_violations(
    schema_db_conn: duckdb.DuckDBPyConnection,
):
    # misth_final_ypal has real, nonzero ritual_support (see
    # test_get_decomposition_candidates_misth_final_ypal_real_scores) but --
    # per test_get_co_update_rituals_no_violations_in_corpus -- this corpus has
    # zero violations anywhere. ritual_pairs (the UI drill-down list) narrows
    # to violations only, so it must be empty here even though ritual_support
    # is not.
    result = get_decomposition_candidates(schema_db_conn, None, "misth_final_ypal", min_similarity=0.7)
    triple = next(c for c in result["candidates"] if set(c["columns"]) == {"kodfinal", "kodxrisi", "kodypal"})
    assert triple["ritual_support"] == 9
    assert triple["ritual_pairs"] == []


def test_candidate_ritual_evidence_sums_support_but_filters_pairs_to_violations_only():
    from pb.api.services.schema import _candidate_ritual_evidence

    col_a = {"namespace": None, "table": "t", "column": "a"}
    col_b = {"namespace": None, "table": "t", "column": "b"}
    col_c = {"namespace": None, "table": "t", "column": "c"}
    clean_violation = {"file": "f.srw", "object": "w_f", "proc_name": "p3", "line": 3, "written_column": col_a}

    rituals = [
        {"column_a": col_a, "column_b": col_b, "co_write_support": 2, "violations": []},
        {"column_a": col_b, "column_b": col_c, "co_write_support": 3, "violations": [clean_violation]},
        # Different table -- must not be counted in the "t" block at all.
        {
            "column_a": {"namespace": None, "table": "other", "column": "a"},
            "column_b": {"namespace": None, "table": "other", "column": "b"},
            "co_write_support": 5,
            "violations": [],
        },
    ]

    support, pairs = _candidate_ritual_evidence(rituals, None, "t", {"a", "b", "c"})
    assert support == 5
    assert len(pairs) == 1
    assert pairs[0]["column_a"] == col_b
    assert pairs[0]["column_b"] == col_c


def test_get_window_table_lattice_counts(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_window_table_lattice(schema_db_conn)
    assert len(result["windows"]) == 64
    assert len(result["tables"]) == 34
    assert result["pairs"] == 134
    assert len(result["concepts"]) == 49


def test_get_window_table_lattice_top_and_bottom_concepts(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_window_table_lattice(schema_db_conn)
    top = max(result["concepts"], key=lambda c: len(c["extent"]))
    assert len(top["extent"]) == 64
    assert top["intent"] == []

    bottom = max(result["concepts"], key=lambda c: len(c["intent"]))
    assert len(bottom["intent"]) == 34
    assert bottom["extent"] == []


def test_get_window_table_lattice_finds_usrmembers_concept(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_window_table_lattice(schema_db_conn)
    matches = [c for c in result["concepts"] if set(c["extent"]) == {"w_usrgroups_list", "w_usrusers_list"}]
    assert len(matches) == 1
    assert matches[0]["intent"] == ["usrmembers"]


def test_get_window_table_lattice_concepts_reconstruct_all_pairs(schema_db_conn: duckdb.DuckDBPyConnection):
    # A formal concept lattice is faithful: unioning every concept's
    # extent x intent must reproduce the exact original incidence relation,
    # with no spurious or missing pairs.
    result = get_window_table_lattice(schema_db_conn)
    reconstructed = {
        (window, table) for c in result["concepts"] for window in c["extent"] for table in c["intent"]
    }
    assert len(reconstructed) == result["pairs"]


def test_get_window_table_lattice_covers_reference_valid_concepts(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_window_table_lattice(schema_db_conn)
    n = len(result["concepts"])
    assert len(result["covers"]) > 0
    for cover in result["covers"]:
        assert 0 <= cover["upper"] < n
        assert 0 <= cover["lower"] < n
        upper_extent = set(result["concepts"][cover["upper"]]["extent"])
        lower_extent = set(result["concepts"][cover["lower"]]["extent"])
        assert lower_extent < upper_extent  # strict subset: lower is more specific
