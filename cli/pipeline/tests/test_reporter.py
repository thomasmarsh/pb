"""Unit tests for pb.pipeline.reporter.RecordingReporter and DiagnosticsCollector.

These tests require no cabal build and no duckdb — pure Python.
"""

import json
import re
import threading
import time

from pb.lib.state import FileDiff
from pb.pipeline.reporter import (
    DiagnosticsCollector,
    RecordingReporter,
    _format_ddl_loaded,
    _format_warning,
    _LiveRunnerProgress,
)


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


# ── DiagnosticsCollector ─────────────────────────────────────────────────────


def _step_event(label: str, *, elapsed_ms: float | None = None,
                input_rows: dict[str, int] | None = None,
                derived_rows: dict[str, int] | None = None,
                residency_mb: float | None = None,
                since_start_ms: float | None = None) -> dict:
    ev: dict = {"tag": "step", "label": label}
    if elapsed_ms is not None:
        ev["elapsed_ms"] = elapsed_ms
    if input_rows:
        ev["input_rows"] = input_rows
    if derived_rows:
        ev["derived_rows"] = derived_rows
    if residency_mb is not None:
        ev["residency_mb"] = residency_mb
    if since_start_ms is not None:
        ev["since_start_ms"] = since_start_ms
    return ev


def test_diagnostics_collector_step_events():
    c = DiagnosticsCollector()
    c.on_event(_step_event("risk_count", input_rows={"schema_objects": 22756}))
    c.on_event(_step_event("risk_count", elapsed_ms=120000, derived_rows={"risk_count": 500}))
    report = c.generate_json()
    steps = report["steps"]
    assert len(steps) == 1
    s = steps[0]
    assert s["label"] == "risk_count"
    assert s["elapsed_ms"] == 120000
    assert s["input_rows"] == {"schema_objects": 22756}
    assert s["derived_rows"] == {"risk_count": 500}


def test_diagnostics_collector_multiple_steps():
    c = DiagnosticsCollector()
    c.on_event(_step_event("step_a", input_rows={"r1": 100}, elapsed_ms=1000, derived_rows={"out": 50}))
    c.on_event(_step_event("step_b", input_rows={"r2": 200}, elapsed_ms=2000, derived_rows={"out2": 75}))
    report = c.generate_json()
    assert len(report["steps"]) == 2
    assert report["steps"][0]["label"] == "step_a"
    assert report["steps"][1]["label"] == "step_b"


def test_diagnostics_collector_peak_residency():
    c = DiagnosticsCollector()
    c.on_event(_step_event("big_step", input_rows={"r": 10}))
    c.on_event(_step_event("big_step", elapsed_ms=5000, residency_mb=1000))
    c.on_event(_step_event("big_step", elapsed_ms=10000, residency_mb=14800))
    c.on_event(_step_event("big_step", elapsed_ms=15000, residency_mb=145))
    report = c.generate_json()
    s = report["steps"][0]
    assert s["peak_residency_mb"] == 14800


def test_diagnostics_collector_phase_events():
    c = DiagnosticsCollector()
    c.on_event({"tag": "phase", "name": "A"})
    c.on_event(_step_event("parse_file", elapsed_ms=5000, derived_rows={"objects": 1051}))
    c.on_event({"tag": "phase", "name": "B"})
    c.on_event(_step_event("risk_count", elapsed_ms=60000))
    report = c.generate_json()
    assert len(report["phases"]) == 2
    assert report["phases"][0]["name"] == "A"
    assert report["phases"][1]["name"] == "B"


def test_diagnostics_collector_warnings():
    c = DiagnosticsCollector()
    c.on_event({"tag": "warning", "message": "--ddl given but PB_SQL_WORKER not set"})
    c.on_event(_step_event("ok_step", elapsed_ms=100))
    report = c.generate_json()
    assert report["warnings"] == ["--ddl given but PB_SQL_WORKER not set"]


def test_diagnostics_collector_empty_run():
    c = DiagnosticsCollector()
    report = c.generate_json()
    assert report["steps"] == []
    assert report["phases"] == []
    assert report["warnings"] == []
    assert "total_elapsed_ms" in report


def test_diagnostics_collector_html_format():
    c = DiagnosticsCollector()
    c.on_event(_step_event("risk_count", input_rows={"reaches": 150000}, elapsed_ms=120000, derived_rows={"risk_count": 500}, residency_mb=14800))
    c.on_event(_step_event("taint_reaches", input_rows={"taint_edge": 5594106}, elapsed_ms=45200, derived_rows={"taint_reaches": 1200}))
    out = c.generate_html()
    assert "<table>" in out
    assert "risk_count" in out
    assert "taint_reaches" in out
    assert "14.5GB" in out  # 14800 MB ≈ 14.5GB


def test_diagnostics_collector_timeline_svg():
    c = DiagnosticsCollector()
    c.on_event({"tag": "phase", "name": "B", "since_start_ms": 0})
    c.on_event(_step_event("Datalog: running [reaches]", since_start_ms=10))
    c.on_event(_step_event("Datalog: running [reaches]", elapsed_ms=500, since_start_ms=510))
    out = c.generate_html()
    assert "<svg" in out
    assert "Datalog ruleset run" in out  # legend entry
    assert "Datalog: running [reaches] — 0.5s" in out  # native <title> tooltip text


def test_diagnostics_collector_timeline_omitted_when_no_timing_data():
    c = DiagnosticsCollector()
    c.on_event(_step_event("step1", elapsed_ms=1000))  # no since_start_ms
    out = c.generate_html()
    assert "<svg" not in out


def test_diagnostics_collector_phase_a_workers_rendered_in_timeline():
    """Phase A's concurrent per-file workers (worker_start/worker_done, not
    step/phase) must show up in the report -- this is the whole reason
    since_start_ms was added: worker contributions weren't visible at all
    before Phase A's own events carried it."""
    c = DiagnosticsCollector()
    c.on_event({"tag": "worker_start", "worker": 0, "file": "src/w_order.srw", "since_start_ms": 10})
    c.on_event({"tag": "worker_start", "worker": 1, "file": "src/w_customer.srw", "since_start_ms": 12})
    c.on_event({"tag": "worker_done", "worker": 0, "file": "src/w_order.srw", "ok": True, "since_start_ms": 40})
    c.on_event({"tag": "worker_done", "worker": 1, "file": "src/w_customer.srw", "ok": True, "since_start_ms": 55})

    report = c.generate_json()
    workers = report["phase_a_workers"]
    assert len(workers) == 2
    assert {w["worker"] for w in workers} == {0, 1}
    assert workers[0]["file"] == "src/w_order.srw"
    assert workers[0]["end_since_start_ms"] == 40

    out = c.generate_html()
    assert "Worker 0" in out
    assert "Worker 1" in out
    assert "File parsing (Phase A)" in out  # legend entry
    assert "w_order.srw" in out  # native tooltip uses the basename


def test_diagnostics_collector_many_workers_fold_into_one_lane():
    """Past _MAX_WORKER_LANES, per-worker lanes fold into one aggregate lane
    -- individual bars still identify their worker via tooltip, but there is
    no dedicated row per worker (which would make the chart unboundedly
    tall on a many-core machine)."""
    c = DiagnosticsCollector()
    for w in range(20):
        c.on_event({"tag": "worker_start", "worker": w, "file": f"f{w}.srw", "since_start_ms": w})
        c.on_event({"tag": "worker_done", "worker": w, "file": f"f{w}.srw", "ok": True, "since_start_ms": w + 5})
    out = c.generate_html()
    assert 'class="lane-label">Worker 0<' not in out
    assert 'class="lane-label">File parsing (Phase A)<' in out


def test_diagnostics_collector_nested_steps_merge_not_split():
    """A Progress.timedStep nested inside another (e.g. runPass67's "Building
    call graph" wrapping "Taint classification") must not produce a bogus
    all-dashes row for the outer step, or split its start/end across two
    separate report rows."""
    c = DiagnosticsCollector()
    c.on_event(_step_event("Building call graph", since_start_ms=100))
    c.on_event(_step_event("Taint classification", since_start_ms=150))
    c.on_event(_step_event("Taint classification", elapsed_ms=20, since_start_ms=170))
    c.on_event(_step_event("Building call graph", elapsed_ms=500, since_start_ms=600))
    report = c.generate_json()
    by_label = {s["label"]: s for s in report["steps"]}
    assert len(report["steps"]) == 2
    assert by_label["Building call graph"]["elapsed_ms"] == 500
    assert by_label["Building call graph"]["start_since_start_ms"] == 100
    assert by_label["Building call graph"]["end_since_start_ms"] == 600
    assert by_label["Taint classification"]["elapsed_ms"] == 20
    # Outer step is listed first: first-seen order, not completion order.
    assert report["steps"][0]["label"] == "Building call graph"


def test_diagnostics_collector_write(tmp_path):
    c = DiagnosticsCollector()
    c.on_event(_step_event("step1", elapsed_ms=1000))
    out = tmp_path / "diag"
    c.write(str(out))
    assert (tmp_path / "diag.json").exists()
    assert (tmp_path / "diag.html").exists()
    data = json.loads((tmp_path / "diag.json").read_text())
    assert len(data["steps"]) == 1
    html_text = (tmp_path / "diag.html").read_text()
    assert "step1" in html_text


def test_diagnostics_collector_partial_run():
    """Collector handles a step that started but never completed (SIGINT scenario)."""
    c = DiagnosticsCollector()
    c.on_event(_step_event("started_never_done", input_rows={"r": 10}))
    c.on_event(_step_event("next_step", input_rows={"r2": 20}, elapsed_ms=500))
    report = c.generate_json()
    # The incomplete step should still appear with what we know
    assert len(report["steps"]) == 2
    incomplete = report["steps"][0]
    assert incomplete["label"] == "started_never_done"
    assert incomplete["elapsed_ms"] is None  # never completed


def test_diagnostics_collector_json_serialisable():
    c = DiagnosticsCollector()
    c.on_event(_step_event("s1", input_rows={"r": 10}, elapsed_ms=100, derived_rows={"o": 5}))
    c.on_event({"tag": "phase", "name": "A"})
    c.on_event({"tag": "warning", "message": "test"})
    # Must not raise
    json.dumps(c.generate_json())


def test_diagnostics_collector_snapshot_in_flight_step_grows():
    c = DiagnosticsCollector()
    c.on_event(_step_event("Datalog: running [reaches]", since_start_ms=0, input_rows={"r": 5}))
    time.sleep(0.02)
    snap = c.snapshot()
    assert snap["status"] == "running"
    assert snap["current"]["label"] == "Datalog: running [reaches]"
    assert snap["current"]["input_rows"] == {"r": 5}
    assert snap["current"]["elapsed_ms"] >= 15
    assert snap["steps"] == []
    bar_match = re.search(r'<rect x="[0-9.]+" y="[0-9.]+" width="([0-9.]+)"[^>]*class="bar series-1"', snap["timeline_html"])
    assert bar_match is not None
    assert float(bar_match.group(1)) > 1000
    assert "still running" in snap["timeline_html"]


def test_diagnostics_collector_snapshot_open_worker_rendered_live():
    c = DiagnosticsCollector()
    c.on_event({"tag": "worker_start", "worker": 0, "file": "src/w_order.srw", "since_start_ms": 0})
    time.sleep(0.02)
    snap = c.snapshot()
    out = snap["timeline_html"]
    assert 'class="lane-label">Worker 0<' in out
    assert "w_order.srw" in out
    assert len(snap["workers"]) == 1
    assert snap["workers"][0]["worker"] == 0
    assert snap["workers"][0]["file"] == "src/w_order.srw"
    assert snap["workers"][0]["start_since_start_ms"] == 0
    assert snap["workers"][0]["elapsed_ms"] >= 15


def test_diagnostics_collector_snapshot_completed_step_not_extended():
    c = DiagnosticsCollector()
    c.on_event(_step_event("risk_count", since_start_ms=100))
    c.on_event(_step_event("risk_count", elapsed_ms=500, derived_rows={"risk_count": 50}, since_start_ms=600))
    snap = c.snapshot()
    assert snap["current"] is None
    assert snap["steps"] == [{"label": "risk_count", "elapsed_ms": 500, "input_rows": {}, "derived_rows": {"risk_count": 50}, "peak_residency_mb": None}]
    assert c.generate_json(now_ms=1000)["steps"][0]["end_since_start_ms"] == 600


def test_diagnostics_collector_snapshot_current_step_derivation_with_nesting():
    c = DiagnosticsCollector()
    c.on_event(_step_event("Building call graph", since_start_ms=100))
    c.on_event(_step_event("Taint classification", since_start_ms=150))
    snap = c.snapshot()
    assert snap["current"]["label"] == "Taint classification"
    c.on_event(_step_event("Taint classification", elapsed_ms=20, since_start_ms=170))
    snap = c.snapshot()
    assert snap["current"]["label"] == "Building call graph"
    assert [s["label"] for s in snap["steps"]] == ["Taint classification"]


def test_diagnostics_collector_snapshot_status_running_then_complete_after_finish():
    c = DiagnosticsCollector()
    assert c.snapshot()["status"] == "running"
    c.finish()
    assert c.snapshot()["status"] == "complete"


def test_diagnostics_collector_snapshot_no_false_gap_for_in_flight_step():
    c = DiagnosticsCollector()
    c.on_event(_step_event("Datalog: running [reaches]", since_start_ms=0))
    snap = c.snapshot()
    assert "Unaccounted time" not in snap["timeline_html"]


def test_diagnostics_collector_snapshot_json_serialisable():
    c = DiagnosticsCollector()
    c.on_event(_step_event("completed_step", since_start_ms=100, elapsed_ms=500))
    c.on_event(_step_event("in_flight_step", since_start_ms=200, input_rows={"r": 10}))
    c.on_event({"tag": "worker_start", "worker": 0, "file": "src/w_order.srw", "since_start_ms": 0})
    json.dumps(c.snapshot())


def test_diagnostics_collector_now_ms_default_preserves_postrun_rendering():
    c = DiagnosticsCollector()
    c.on_event({"tag": "worker_start", "worker": 0, "file": "src/w_order.srw", "since_start_ms": 10})
    c.on_event(_step_event("completed", since_start_ms=100, elapsed_ms=500))
    out = c.generate_html()
    assert "Worker 0" not in out
    assert "w_order.srw" not in out
    c2 = DiagnosticsCollector()
    c2.on_event(_step_event("started_never_done", since_start_ms=100))
    assert c2.generate_json()["steps"][0]["end_since_start_ms"] == 100


def test_diagnostics_collector_generate_json_now_ms_extends_in_flight():
    c = DiagnosticsCollector()
    c.on_event(_step_event("started_never_done", since_start_ms=100))
    assert c.generate_json(now_ms=1000)["steps"][0]["end_since_start_ms"] == 1000


def test_diagnostics_collector_concurrent_on_event_and_snapshot():
    c = DiagnosticsCollector()
    stop = threading.Event()

    def writer(n: int) -> None:
        for i in range(300):
            if stop.is_set():
                return
            c.on_event(_step_event(f"step_{i % 4}", since_start_ms=i))
            c.on_event({"tag": "worker_start", "worker": n, "file": f"f{i}.srw", "since_start_ms": i})
            c.on_event({"tag": "worker_done", "worker": n, "file": f"f{i}.srw", "ok": True, "since_start_ms": i + 1})

    writers = [threading.Thread(target=writer, args=(i,)) for i in range(4)]
    for t in writers:
        t.start()
    for _ in range(20):
        json.dumps(c.snapshot())
        c.generate_json(now_ms=1000)
        c.generate_html()
    stop.set()
    for t in writers:
        t.join()


# ── _LiveRunnerProgress render branch (doc/plan/187-perf-hotspots.md sec16) ────
#
# pbc runs several more named steps after phase A0's files finish parsing
# (building the workspace type env, the control index, the type-check
# workspace) before Phase B's own "phase" event arrives. Regression coverage
# for the bug this exposed: the live progress line stayed frozen on the
# N/N file-count bar for that entire span, with no indication anything was
# still running, because the bar view was gated on phase_name alone.


def _render_text(prog: _LiveRunnerProgress) -> str:
    from rich.console import Console

    console = Console(record=True, width=200, force_terminal=False)
    console.print(prog._render())
    return console.export_text()


def test_runner_progress_shows_bar_while_files_still_parsing():
    prog = _LiveRunnerProgress(console=None)
    prog.on_event({"tag": "total", "n": 3})
    prog.on_event({"tag": "phase", "name": "A0", "total": 3})
    prog.on_event({"tag": "file_done", "phase": "A0"})

    text = _render_text(prog)
    assert "1/3" in text
    assert "█" in text or "░" in text


def test_runner_progress_switches_to_step_label_once_parsing_done():
    prog = _LiveRunnerProgress(console=None)
    prog.on_event({"tag": "total", "n": 2})
    prog.on_event({"tag": "phase", "name": "A0", "total": 2})
    prog.on_event({"tag": "file_done", "phase": "A0"})
    prog.on_event({"tag": "file_done", "phase": "A0"})
    # Still phase "A0" -- no new "phase" event yet -- but every file is done,
    # and a named step is now running (mirrors runModeDb's
    # "Building workspace type env" landing after the parse loop).
    prog.on_event({"tag": "step", "label": "Building workspace type env"})

    text = _render_text(prog)
    assert "2/2" not in text
    assert "█" not in text and "░" not in text
    assert "Building workspace type env" in text


def test_diagnostics_collector_snapshot_stable_after_finish():
    """Snapshot data MUST be identical across repeated calls after finish().

    This is the correctness invariant: once the job is done, the timeline
    durations and step data cannot change between page loads.
    """
    c = DiagnosticsCollector()
    # Simulate a realistic pipeline: three sequential steps.
    c.on_event(_step_event("Phase B analysis (SQL)", since_start_ms=0, elapsed_ms=6500))
    c.on_event(_step_event("Schema closure", since_start_ms=6500, elapsed_ms=3800))
    c.on_event(_step_event("Building call graph", since_start_ms=10300, elapsed_ms=2200))
    c.finish()

    snap1 = c.snapshot()
    snap2 = c.snapshot()
    snap3 = c.snapshot()

    # elapsed_ms must be identical across all calls
    assert snap1["elapsed_ms"] == snap2["elapsed_ms"] == snap3["elapsed_ms"]
    # Total should be max(start + elapsed) = 10300 + 2200 = 12500
    assert snap1["elapsed_ms"] == 12500.0
    # Steps list must be identical
    assert snap1["steps"] == snap2["steps"] == snap3["steps"]
    # Status must always be complete
    assert snap1["status"] == snap2["status"] == snap3["status"] == "complete"
