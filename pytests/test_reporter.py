"""Unit tests for pbtools.reporter.RecordingReporter.

These tests require no cabal build and no duckdb — pure Python.
"""
import json

from pbtools.reporter import RecordingReporter
from pbtools.state import FileDiff


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
    assert r.events == [{'type': 'building'}]


def test_status_is_context_manager_and_records():
    r = RecordingReporter()
    with r.status('scanning'):
        pass
    assert r.events == [{'type': 'status', 'msg': 'scanning'}]


def test_indexed():
    r = RecordingReporter()
    r.indexed(1234)
    assert r.events == [{'type': 'indexed', 'row_count': 1234}]


# ── diff_summary ──────────────────────────────────────────────────────────────

def test_diff_summary():
    r = RecordingReporter()
    r.diff_summary(_diff(new=3, changed=2, deleted=1, unchanged=10))
    assert r.events == [{
        'type': 'diff_summary',
        'new': 3, 'changed': 2, 'deleted': 1, 'unchanged': 10,
    }]


# ── parse_progress ────────────────────────────────────────────────────────────

def test_parse_progress_records_start_and_end():
    r = RecordingReporter()
    with r.parse_progress(5, 'Parsing') as _:
        pass
    assert r.events[0] == {'type': 'parse_start', 'total': 5, 'label': 'Parsing'}
    assert r.events[-1] == {'type': 'parse_end', 'errors': 0}


def test_parse_progress_advance_and_error():
    r = RecordingReporter()
    with r.parse_progress(3, 'P') as prog:
        prog.advance()
        prog.on_error({'file': 'bad.sr', 'error': 'lex error at line 5'})
        prog.advance()

    assert prog.error_count == 1

    advance_events = [e for e in r.events if e['type'] == 'parse_advance']
    error_events   = [e for e in r.events if e['type'] == 'parse_error']
    assert len(advance_events) == 2
    assert len(error_events) == 1
    assert error_events[0] == {
        'type': 'parse_error', 'file': 'bad.sr', 'error': 'lex error at line 5',
    }
    assert r.events[-1] == {'type': 'parse_end', 'errors': 1}


def test_parse_error_count_accessible_after_context():
    r = RecordingReporter()
    with r.parse_progress(2, 'P') as prog:
        prog.on_error({'file': 'a.sr', 'error': 'x'})
        prog.on_error({'file': 'b.sr', 'error': 'y'})
    assert prog.error_count == 2


# ── analyze_progress ──────────────────────────────────────────────────────────

def test_analyze_progress_records_all_stage_types():
    r = RecordingReporter()
    with r.analyze_progress(10) as prog:
        for _ in range(3):
            prog.advance_extract()
        for _ in range(3):
            prog.advance_cyclomatic()
        prog.advance_metrics('betweenness')
        prog.advance_metrics('pagerank')
        prog.advance_metrics('inserting rows')
        prog.advance_metrics('done')

    assert r.events[0] == {'type': 'analyze_start', 'n_procs': 10}
    assert r.events[-1] == {'type': 'analyze_end'}

    extract_count    = sum(1 for e in r.events if e['type'] == 'analyze_extract')
    cyclomatic_count = sum(1 for e in r.events if e['type'] == 'analyze_cyclomatic')
    metrics_labels   = [e['label'] for e in r.events if e['type'] == 'analyze_metrics']

    assert extract_count == 3
    assert cyclomatic_count == 3
    assert metrics_labels == ['betweenness', 'pagerank', 'inserting rows', 'done']


# ── done ──────────────────────────────────────────────────────────────────────

def test_done_without_diff():
    r = RecordingReporter()
    r.done(parsed=777, errors=0)
    assert r.events[-1] == {
        'type': 'done', 'parsed': 777, 'errors': 0, 'rows': None, 'diff': None,
    }


def test_done_with_diff_and_rows():
    r = RecordingReporter()
    r.done(parsed=5, errors=2, rows=12345, diff=_diff(new=3, changed=2, deleted=1))
    ev = r.events[-1]
    assert ev['type'] == 'done'
    assert ev['errors'] == 2
    assert ev['rows'] == 12345
    assert ev['diff'] == {'new': 3, 'changed': 2, 'deleted': 1}


def test_done_nothing_to_do():
    r = RecordingReporter()
    r.done(parsed=0, errors=0, diff=_diff(unchanged=342))
    ev = r.events[-1]
    assert ev['diff'] == {'new': 0, 'changed': 0, 'deleted': 0}
    assert ev['parsed'] == 0
    assert ev['errors'] == 0


# ── JSON-serialisability ──────────────────────────────────────────────────────

def test_all_events_are_json_serialisable():
    r = RecordingReporter()
    r.building()
    with r.status('s'):
        pass
    r.diff_summary(_diff(new=1, changed=1, deleted=1, unchanged=1))
    with r.parse_progress(2, 'P') as prog:
        prog.advance()
        prog.on_error({'file': 'f', 'error': 'e'})
    with r.analyze_progress(1) as ap:
        ap.advance_extract()
        ap.advance_cyclomatic()
        ap.advance_metrics('done')
    r.indexed(99)
    r.done(parsed=2, errors=1, rows=99, diff=_diff(new=1, changed=1))

    # Must not raise
    json.dumps(r.events)
