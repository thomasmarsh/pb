"""Unit tests for pb.pipeline.reporter.RecordingReporter.

These tests require no cabal build and no duckdb — pure Python.
"""

import json

from pb.lib.state import FileDiff
from pb.pipeline.reporter import RecordingReporter, _format_ddl_loaded, _format_warning


def _diff(new=0, changed=0, deleted=0, unchanged=0) -> FileDiff:
    return FileDiff(
        new=[str(i) for i in range(new)],
        changed=[str(i) for i in range(changed)],
        deleted=[str(i) for i in range(deleted)],
        unchanged=[str(i) for i in range(unchanged)],
    )


# ── basic events ──────────────────────────────────────────────────────────────


def test_building():
    r = RecordingReporter()
    r.building()
    assert r.events == [{"type": "building"}]


def test_extracting_progress():
    r = RecordingReporter()
    with r.extracting_progress(3) as prog:
        prog.advance()
        prog.advance()
    assert r.events[0] == {"type": "extracting_start", "total": 3}
    assert sum(1 for e in r.events if e["type"] == "extracting_advance") == 2
    assert r.events[-1] == {"type": "extracting_end"}


def test_status_is_context_manager_and_records():
    r = RecordingReporter()
    with r.status("scanning"):
        pass
    assert r.events == [{"type": "status", "msg": "scanning"}]


# ── indexing_step ─────────────────────────────────────────────────────────────


def test_indexing_step_records_chunks():
    r = RecordingReporter()
    with r.indexing_step() as advance:
        advance(500)
        advance(300)
    assert r.events == [
        {"type": "indexing_start"},
        {"type": "index_chunk", "n": 500},
        {"type": "index_chunk", "n": 300},
        {"type": "indexing_end"},
    ]


# ── parse_progress ────────────────────────────────────────────────────────────


def test_parse_progress_records_start_and_end():
    r = RecordingReporter()
    with r.parse_progress(5, "Parsing") as _:
        pass
    assert r.events[0] == {"type": "parse_start", "total": 5, "label": "Parsing"}
    assert r.events[-1] == {"type": "parse_end", "errors": 0}


def test_parse_progress_advance_and_error():
    r = RecordingReporter()
    with r.parse_progress(3, "P") as prog:
        prog.advance()
        prog.on_error({"file": "bad.sr", "error": "lex error at line 5"})
        prog.advance()

    assert prog.error_count == 1

    advance_events = [e for e in r.events if e["type"] == "parse_advance"]
    error_events = [e for e in r.events if e["type"] == "parse_error"]
    assert len(advance_events) == 2
    assert len(error_events) == 1
    assert error_events[0] == {
        "type": "parse_error",
        "file": "bad.sr",
        "error": "lex error at line 5",
    }
    assert r.events[-1] == {"type": "parse_end", "errors": 1}


def test_parse_error_count_accessible_after_context():
    r = RecordingReporter()
    with r.parse_progress(2, "P") as prog:
        prog.on_error({"file": "a.sr", "error": "x"})
        prog.on_error({"file": "b.sr", "error": "y"})
    assert prog.error_count == 2


# ── analyze_progress ──────────────────────────────────────────────────────────


def test_analyze_progress_records_all_stage_types():
    r = RecordingReporter()
    with r.analyze_progress() as prog:
        prog.start_step("compute metrics")
        prog.advance_metrics("betweenness")
        prog.advance_metrics("pagerank")
        prog.start_step("build type tables")
        prog.start_step("build dataflow tables")

    assert r.events[0] == {"type": "analyze_start"}
    assert r.events[-1] == {"type": "analyze_end"}

    step_labels = [e["label"] for e in r.events if e["type"] == "analyze_step"]
    assert step_labels == ["compute metrics", "build type tables", "build dataflow tables"]

    metrics_labels = [e["label"] for e in r.events if e["type"] == "analyze_metrics"]
    assert metrics_labels == ["betweenness", "pagerank"]


# ── done ──────────────────────────────────────────────────────────────────────


def test_done_without_diff():
    r = RecordingReporter()
    r.done(parsed=777, errors=0)
    assert r.events[-1] == {
        "type": "done",
        "parsed": 777,
        "errors": 0,
        "rows": None,
        "sql_parse_failures": None,
        "diff": None,
    }


def test_done_with_diff_and_rows():
    r = RecordingReporter()
    r.done(parsed=5, errors=2, rows=12345, diff=_diff(new=3, changed=2, deleted=1))
    ev = r.events[-1]
    assert ev["type"] == "done"
    assert ev["errors"] == 2
    assert ev["rows"] == 12345
    assert ev["diff"] == {"new": 3, "changed": 2, "deleted": 1}


def test_done_nothing_to_do():
    r = RecordingReporter()
    r.done(parsed=0, errors=0, diff=_diff(unchanged=342))
    ev = r.events[-1]
    assert ev["diff"] == {"new": 0, "changed": 0, "deleted": 0}
    assert ev["parsed"] == 0
    assert ev["errors"] == 0


# ── DDL diagnostics (ddl_loaded / warning progress events) ────────────────────


def _ddl_event(**overrides) -> dict:
    base = {
        "tag": "ddl_loaded",
        "path": "clims_schema1.sql",
        "namespace": "CLIMS",
        "parse_ok": True,
        "error": None,
        "statements_total": 45,
        "statements_parsed": 45,
        "statements_skipped": 0,
        "tables": 10,
        "primary_keys": 8,
        "foreign_keys": 12,
        "checks": 2,
    }
    base.update(overrides)
    return base


def test_format_ddl_loaded_healthy_file():
    lines = _format_ddl_loaded(_ddl_event())
    assert len(lines) == 1
    assert "✓" in lines[0]
    assert "⚠" not in lines[0]
    assert "CLIMS" in lines[0]
    assert "clims_schema1.sql" in lines[0]
    assert "10 table(s)" in lines[0]
    assert "45/45 statements" in lines[0]


def test_format_ddl_loaded_skipped_statements_flagged():
    lines = _format_ddl_loaded(_ddl_event(statements_parsed=42, statements_skipped=3))
    assert len(lines) == 1
    assert "⚠" in lines[0]
    assert "42/45 statements" in lines[0]


def test_format_ddl_loaded_zero_tables_flagged_even_when_fully_parsed():
    lines = _format_ddl_loaded(
        _ddl_event(tables=0, primary_keys=0, foreign_keys=0, checks=0)
    )
    assert len(lines) == 1
    assert "⚠" in lines[0]
    assert "0 table(s)" in lines[0]


def test_format_ddl_loaded_skipped_previews_shown():
    lines = _format_ddl_loaded(
        _ddl_event(
            statements_parsed=42,
            statements_skipped=3,
            skipped_previews=["[unparsed] CREATE INDEX ...", "[unresolved view] v_x"],
        )
    )
    assert len(lines) == 3
    assert "⚠" in lines[0]
    assert "[unparsed] CREATE INDEX ..." in lines[1]
    assert "[unresolved view] v_x" in lines[2]


def test_format_ddl_loaded_previews_flagged_even_with_zero_skipped_count():
    # Unresolved views never increment statements_skipped, so previews alone
    # must be enough to flag the ⚠ branch.
    lines = _format_ddl_loaded(
        _ddl_event(skipped_previews=["[unresolved view] v_unknown"])
    )
    assert "⚠" in lines[0]
    assert len(lines) == 2
    assert "[unresolved view] v_unknown" in lines[1]


def test_format_ddl_loaded_parse_failure_shows_error():
    lines = _format_ddl_loaded(
        _ddl_event(parse_ok=False, error="unexpected token at line 12", tables=0)
    )
    assert any("✗" in line for line in lines)
    assert any("unexpected token at line 12" in line for line in lines)


def test_format_warning():
    line = _format_warning({"tag": "warning", "message": "--ddl given but PB_SQL_WORKER not set"})
    assert "⚠" in line
    assert "PB_SQL_WORKER" in line


def test_recording_reporter_passes_through_ddl_loaded_event():
    r = RecordingReporter()
    with r.runner_progress() as prog:
        prog.on_event(_ddl_event())
    matches = [e for e in r.events if e.get("tag") == "ddl_loaded"]
    assert len(matches) == 1
    assert matches[0]["type"] == "runner_event"
    assert matches[0]["tables"] == 10


def test_recording_reporter_passes_through_warning_event():
    r = RecordingReporter()
    with r.runner_progress() as prog:
        prog.on_event({"tag": "warning", "message": "--ddl given but PB_SQL_WORKER not set"})
    matches = [e for e in r.events if e.get("tag") == "warning"]
    assert len(matches) == 1
    assert matches[0]["message"] == "--ddl given but PB_SQL_WORKER not set"


# ── JSON-serialisability ──────────────────────────────────────────────────────


def test_all_events_are_json_serialisable():
    r = RecordingReporter()
    r.building()
    with r.extracting_progress(2) as ep:
        ep.advance()
        ep.advance()
    with r.status("s"):
        pass
    with r.parse_progress(2, "P") as prog:
        prog.advance()
        prog.on_error({"file": "f", "error": "e"})
    with r.indexing_step() as advance:
        advance(50)
        advance(49)
    with r.analyze_progress() as ap:
        ap.start_step("compute metrics")
        ap.advance_metrics("done")
    r.done(parsed=2, errors=1, rows=99, diff=_diff(new=1, changed=1))

    # Must not raise
    json.dumps(r.events)
