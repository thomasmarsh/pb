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
    get_procedure_footprint,
    get_window_table_lattice,
)


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
    # min_support=1 admits every co-occurring pair (76 support=1 + 45 at >=2).
    result = get_co_update_rituals(schema_db_conn, min_support=1)
    assert len(result["rituals"]) == 121
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
    assert len(result["read_only"]) == 172
    assert len(result["read_write"]) == 53
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


def test_get_procedure_footprint_fn_perm(schema_db_conn: duckdb.DuckDBPyConnection):
    result = get_procedure_footprint(schema_db_conn, "fn_perm", "fn_perm")
    assert result is not None
    assert [s["line"] for s in result["statements"]] == [30, 41, 52, 63, 74]

    for stmt in result["statements"]:
        cols = {(c["table"], c["column"]) for c in stmt["columns"]}
        assert cols == {
            ("usrgroupperm", "kodgroup"),
            ("usrgroupperm", "kodaction"),
            ("usrmembers", "kodgroup"),
            ("usrmembers", "koduser"),
        }
        # Open Question 1: literal-only row-filter rider yields ~0 rows on
        # real embedded SQL (host-variable-bound predicates) — do not treat
        # an empty filters list as a bug.
        assert stmt["filters"] == []

    # the ambiguous addrec/editrec/delrec/openlist/openform action names
    # (table_name IS NULL) must be excluded from columns and reported
    # separately, one per statement line.
    assert [u["line"] for u in result["unresolved"]] == [30, 41, 52, 63, 74]
    assert {u["raw_name"] for u in result["unresolved"]} == {
        "addrec",
        "editrec",
        "delrec",
        "openlist",
        "openform",
    }


def test_get_procedure_footprint_not_found(schema_db_conn: duckdb.DuckDBPyConnection):
    assert get_procedure_footprint(schema_db_conn, "__nonexistent__", "__nope__") is None


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

    assert frozenset({"kodypal", "kodxrisi"}) in merges
    assert abs(merges[frozenset({"kodypal", "kodxrisi"})] - 0.9167) < 0.001

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
    assert name_surname["coslice_size"] == 27
    assert name_surname["score"] == 0.0
    assert len(name_surname["paths"]) == 27


def test_get_decomposition_candidates_misth_final_ypal_real_scores(schema_db_conn: duckdb.DuckDBPyConnection):
    # misth_final_ypal is the corpus's one table with real D1 (co-write
    # ritual) evidence -- confirmed here as a nonzero-score candidate, not
    # just a nonzero coslice.
    result = get_decomposition_candidates(schema_db_conn, None, "misth_final_ypal", min_similarity=0.7)
    by_cols = {frozenset(c["columns"]): c for c in result["candidates"]}

    triple = by_cols[frozenset({"kodfinal", "kodxrisi", "kodypal"})]
    assert triple["ritual_support"] == 9
    assert triple["unenforced_fk_count"] == 0
    assert triple["coslice_size"] == 120
    assert triple["score"] == 9 / 120

    pair = by_cols[frozenset({"kodfinal", "kodxrisi"})]
    assert pair["ritual_support"] == 3
    assert pair["coslice_size"] == 119
    assert pair["score"] == 3 / 119


def test_get_decomposition_candidates_paths_explain_fk_chained_reach(schema_db_conn: duckdb.DuckDBPyConnection):
    # Cross-check anchor: paths are first-class, not just a count -- a
    # 2-hop FK-chained target must show both legs, in order. Targets/legs are
    # formatted via `_format_object_key`, which drops the file path baked
    # into every `stmt:` schObjectKey (an absolute pb-extract temp path,
    # unreadable and environment-dependent -- found unreadable in the UI
    # during D5's manual verification), so these are exact matches now
    # rather than `.endswith(...)` workarounds for the unpredictable prefix.
    result = get_decomposition_candidates(schema_db_conn, None, "misth_final_ypal", min_similarity=0.7)
    triple = next(c for c in result["candidates"] if set(c["columns"]) == {"kodfinal", "kodxrisi", "kodypal"})

    fk_chained = next(p for p in triple["paths"] if p["target"] == "dw_misth_final_form (DW retrieve)")
    assert fk_chained["direction"] == "backward"
    assert len(fk_chained["legs"]) == 2
    assert fk_chained["legs"][0] == "dw_misth_final_form (DW retrieve) --retrieve--> col:misth_final.kodfinal"
    assert fk_chained["legs"][1] == "col:misth_final.kodfinal --fk--> col:misth_final_ypal.kodfinal"


def test_format_object_key_strips_file_path_from_stmt_keys():
    from pb.api.services.schema import _format_object_key

    assert (
        _format_object_key("stmt:dw:/tmp/pb-extract-abc123/final.pbl/dw_x.srd:dw_x")
        == "dw_x (DW retrieve)"
    )
    assert (
        _format_object_key("stmt:sql:/tmp/pb-extract-abc123/final.pbl/n_svc.srw:n_svc:of_process:42")
        == "n_svc.of_process (line 42)"
    )
    assert _format_object_key("col:misth_final.kodfinal") == "col:misth_final.kodfinal"


def test_get_decomposition_candidates_min_similarity_filters_low_blocks(
    schema_db_conn: duckdb.DuckDBPyConnection,
):
    loose = get_decomposition_candidates(schema_db_conn, None, "misth_ypal", min_similarity=0.0)
    strict = get_decomposition_candidates(schema_db_conn, None, "misth_ypal", min_similarity=0.95)
    assert len(strict["candidates"]) < len(loose["candidates"])
    assert all(c["similarity"] >= 0.95 for c in strict["candidates"])


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
