"""Unified output protocol for pipeline operations.

Two implementations:
  LiveReporter        — rich-backed; for CLI use
  RecordingReporter   — accumulates JSON-serialisable events; for tests
"""

from __future__ import annotations

import html
import json
import os
import queue
import threading
import time
from collections.abc import Callable, Iterator
from contextlib import AbstractContextManager, contextmanager
from dataclasses import dataclass, field
from typing import Any, Protocol

from pb.lib.state import FileDiff

# ── ExtractProgress ────────────────────────────────────────────────────────────


class ExtractProgress(Protocol):
    def advance(self) -> None: ...


class _LiveExtractProgress:
    def __init__(self, progress, task) -> None:
        self._progress = progress
        self._task = task

    def advance(self) -> None:
        self._progress.advance(self._task)


class _RecordingExtractProgress:
    def __init__(self, events: list[dict]) -> None:
        self._events = events

    def advance(self) -> None:
        self._events.append({"type": "extracting_advance"})


# ── ParseProgress ──────────────────────────────────────────────────────────────


class ParseProgress(Protocol):
    error_count: int

    def advance(self) -> None: ...
    def on_error(self, obj: dict) -> None: ...


class _LiveParseProgress:
    def __init__(self, progress, task) -> None:
        self._progress = progress
        self._task = task
        self.error_count = 0

    def advance(self) -> None:
        self._progress.advance(self._task)

    def on_error(self, obj: dict) -> None:
        from pb.pipeline.env import env

        self.error_count += 1
        self._progress.update(self._task, err_str=f"[red]⚠ {self.error_count} errors[/red]")
        self._progress.console.print(env.runner.render_error(obj))


class _RecordingParseProgress:
    def __init__(self, events: list[dict]) -> None:
        self._events = events
        self.error_count = 0

    def advance(self) -> None:
        self._events.append({"type": "parse_advance"})

    def on_error(self, obj: dict) -> None:
        self.error_count += 1
        self._events.append({"type": "parse_error", "file": obj.get("file"), "error": obj.get("error")})


# ── AnalyzeProgress ────────────────────────────────────────────────────────────


class AnalyzeProgress(Protocol):
    def start_step(self, label: str) -> None: ...
    def advance_metrics(self, label: str) -> None: ...


class _LiveAnalyzeProgress:
    def __init__(self, progress, task) -> None:
        self._progress = progress
        self._task = task
        self._step_name: str = ""
        self._step_start: float = 0.0
        self.times: list[tuple[str, float]] = []

    def start_step(self, label: str) -> None:
        import time

        now = time.monotonic()
        if self._step_name:
            self.times.append((self._step_name, now - self._step_start))
        self._step_name = label
        self._step_start = now
        self._progress.update(self._task, description=f"[2/2] {label}")

    def advance_metrics(self, label: str) -> None:
        self._progress.update(self._task, description=f"[2/2] {self._step_name} [{label}]")

    def _finish(self) -> None:
        import time

        if self._step_name:
            self.times.append((self._step_name, time.monotonic() - self._step_start))


class _RecordingAnalyzeProgress:
    def __init__(self, events: list[dict]) -> None:
        self._events = events

    def start_step(self, label: str) -> None:
        self._events.append({"type": "analyze_step", "label": label})

    def advance_metrics(self, label: str) -> None:
        self._events.append({"type": "analyze_metrics", "label": label})


# ── RunnerProgress ─────────────────────────────────────────────────────────────


class RunnerProgress(Protocol):
    @property
    def parsed_count(self) -> int: ...
    def on_event(self, event: dict) -> None: ...


def _format_ddl_loaded(event: dict) -> list[str]:
    """Rich-markup lines for one --ddl file's load result (pbc's "ddl_loaded"
    progress event). Flags two distinct failure shapes: whole-file structural
    failure (parse_ok=False — e.g. the SQL bridge itself errored) and silent
    partial/total loss (parse_ok=True but statements_skipped > 0, tables == 0,
    or skipped_previews non-empty) — the latter is what happens when sqlglot
    can't structurally parse a statement (e.g. an unmodeled Oracle keyword)
    and falls back to an opaque Command instead of raising, or when a CREATE
    VIEW's fixed-point resolution loop never resolves it, so nothing else in
    the pipeline ever sees an error for it. skipped_previews (present since
    the skipped-statement-preview threading follow-up) carries one preview
    line per lost statement, printed indented under the summary line so the
    user can see *which* statement failed, not just how many."""
    namespace = event.get("namespace") or "(default)"
    path = event.get("path", "?")
    parse_ok = event.get("parse_ok", True)

    if not parse_ok:
        lines = [f"[red]✗[/red] DDL  [bold]{namespace}[/bold]  {path}  — failed to parse"]
        error = event.get("error")
        if error:
            lines.append(f"    [red]{error}[/red]")
        return lines

    total = event.get("statements_total", 0)
    parsed = event.get("statements_parsed", 0)
    skipped = event.get("statements_skipped", 0)
    tables = event.get("tables", 0)
    pks = event.get("primary_keys", 0)
    fks = event.get("foreign_keys", 0)
    checks = event.get("checks", 0)
    previews = event.get("skipped_previews", [])

    counts = f"{tables} table(s) · {pks} pk(s) · {fks} fk(s) · {checks} check(s)"
    stmt_summary = f"{parsed}/{total} statements"

    if skipped > 0 or tables == 0 or previews:
        skip_note = f", [yellow]{skipped} skipped[/yellow]" if skipped > 0 else ""
        lines = [
            f"[yellow]⚠[/yellow] DDL  [bold]{namespace}[/bold]  {path}  {counts}"
            f"  ({stmt_summary}{skip_note})"
        ]
        lines.extend(f"    [yellow]· {preview}[/yellow]" for preview in previews)
        return lines
    return [f"[green]✓[/green] DDL  [bold]{namespace}[/bold]  {path}  {counts}  ({stmt_summary})"]


def _format_warning(event: dict) -> str:
    return f"[yellow]⚠[/yellow] {event.get('message', '')}"


@dataclass
class _StepInfo:
    """One completed step's metadata for the scrolling history."""

    label: str
    elapsed_ms: float | None = None
    input_rows: dict[str, int] = field(default_factory=dict)
    derived_rows: dict[str, int] = field(default_factory=dict)
    residency_mb: float | None = None


# Categorical step-kind taxonomy for the HTML report's timeline swim lanes,
# derived from each step's label prefix. Fixed order matches the validated
# default categorical palette's slots 1-5 (references/palette.md in the
# dataviz skill) -- never reordered/cycled per that palette's own rule.
_KIND_ORDER = [
    "Datalog ruleset run",
    "Datalog materialize/characterize",
    "Pipeline orchestration",
]


def _step_kind(label: str) -> str:
    if label.startswith("Datalog: running"):
        return "Datalog ruleset run"
    if label.startswith("Datalog:"):
        return "Datalog materialize/characterize"
    return "Pipeline orchestration"


# Below this, an unaccounted span is noise (heartbeats/short gaps between
# adjacent steps), not a real instrumentation gap worth flagging.
_MIN_GAP_MS = 300.0


def _find_gaps(intervals: list[tuple[float, float]], total_span_ms: float) -> list[tuple[float, float]]:
    """Spans of [0, total_span_ms] covered by no interval, at least
    _MIN_GAP_MS wide -- the generic net for "something ran with zero
    progress events" that catches whatever gap turns up next, not just the
    ones a human happened to notice and hand-instrument today."""
    if not intervals:
        return [(0.0, total_span_ms)] if total_span_ms >= _MIN_GAP_MS else []
    merged: list[tuple[float, float]] = []
    for start, end in sorted(intervals):
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    gaps = []
    cursor = 0.0
    for start, end in merged:
        if start - cursor >= _MIN_GAP_MS:
            gaps.append((cursor, start))
        cursor = max(cursor, end)
    if total_span_ms - cursor >= _MIN_GAP_MS:
        gaps.append((cursor, total_span_ms))
    return gaps


# Shared by the post-run diagnostics report (_HTML_TEMPLATE below) and the
# live progress page (cli/api/src/pb/api/static/progress.html), so the two
# renderings of the same timeline/legend/table markup never drift apart.
VIZ_ROOT_CSS = """\
  .viz-root {
    color-scheme: light;
    --surface-1: #fcfcfb;
    --text-primary: #0b0b0b;
    --text-secondary: #52514e;
    --grid: #e3e2de;
    --series-1: #2a78d6;
    --series-2: #008300;
    --series-3: #e87ba4;
    --series-4: #eda100;
    --series-5: #1baf7a;
    --series-6: #eb6834;
  }
  @media (prefers-color-scheme: dark) {
    .viz-root {
      color-scheme: dark;
      --surface-1: #1a1a19;
      --text-primary: #ffffff;
      --text-secondary: #c3c2b7;
      --grid: #33322f;
      --series-1: #3987e5;
      --series-2: #008300;
      --series-3: #d55181;
      --series-4: #c98500;
      --series-5: #199e70;
      --series-6: #d95926;
    }
  }
  .timeline svg { max-width: 100%; height: auto; display: block; }
  .gap { fill: var(--text-secondary); opacity: 0.12; stroke: var(--text-secondary); stroke-width: 1; stroke-dasharray: 4,3; }
  .phase-guide { stroke: var(--grid); stroke-width: 1; stroke-dasharray: 3,3; }
  .lane-grid { stroke: var(--grid); stroke-width: 1; }
  .phase-label, .axis-tick { fill: var(--text-secondary); font-size: 10px; }
  .lane-label { fill: var(--text-secondary); font-size: 10px; }
  .bar { opacity: 0.92; }
  .bar.series-1 { fill: var(--series-1); }
  .bar.series-2 { fill: var(--series-2); }
  .bar.series-3 { fill: var(--series-3); }
  .bar.series-4 { fill: var(--series-4); }
  .bar.series-5 { fill: var(--series-5); }
  .bar.series-6 { fill: var(--series-6); }
  .legend { display: flex; flex-wrap: wrap; gap: 0.75rem 1.5rem; margin: 0.5rem 0 1.5rem; font-size: 0.85rem; color: var(--text-secondary); }
  .legend-item { display: inline-flex; align-items: center; gap: 0.4rem; }
  .swatch { width: 10px; height: 10px; border-radius: 2px; display: inline-block; }
  .swatch.series-1 { background: var(--series-1); }
  .swatch.series-2 { background: var(--series-2); }
  .swatch.series-3 { background: var(--series-3); }
  .swatch.series-4 { background: var(--series-4); }
  .swatch.series-5 { background: var(--series-5); }
  .swatch.series-6 { background: var(--series-6); }
  table { border-collapse: collapse; width: 100%; font-size: 0.9rem; }
  th, td { text-align: left; padding: 0.35rem 0.75rem; border-bottom: 1px solid var(--grid); }
  th { color: var(--text-secondary); font-weight: 600; }
  ul.warnings li { color: #b25400; }
"""

_HTML_TEMPLATE = """<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Pipeline Diagnostics Report</title>
<style>
{viz_root_css}
  body {{
    background: var(--surface-1);
    color: var(--text-primary);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    max-width: 1200px;
    margin: 2rem auto;
    padding: 0 1rem;
  }}
  h1, h2 {{ font-weight: 600; }}
  h2 {{ margin-top: 2rem; font-size: 1.1rem; color: var(--text-secondary); }}
</style>
</head>
<body class="viz-root">
<h1>Pipeline Diagnostics Report</h1>
<p><strong>Total elapsed:</strong> {total_elapsed}</p>
{phases_html}
{timeline_html}
{table_html}
{warnings_html}
</body>
</html>
"""


@dataclass
class _ReportStep:
    """One step in the diagnostics report."""

    label: str
    elapsed_ms: float | None = None
    input_rows: dict[str, int] = field(default_factory=dict)
    derived_rows: dict[str, int] = field(default_factory=dict)
    peak_residency_mb: float | None = None
    # Absolute offsets from the pbc process's first progress event (its
    # `since_start_ms` wire field) -- unlike elapsed_ms (this step's own
    # duration), these place the step on one timeline shared with every
    # other step and phase, including Phase A's concurrent per-file workers,
    # which do not share a single sequential ordering with Phase B.
    start_since_start_ms: float | None = None
    end_since_start_ms: float | None = None
    last_event_seq: int = 0
    completed_seq: int | None = None


@dataclass
class _WorkerInterval:
    """One file's processing span on one Phase A worker thread."""

    worker: int
    file: str
    start_since_start_ms: float
    end_since_start_ms: float | None


class DiagnosticsCollector:
    """Accumulates pipeline events and generates a post-run diagnostics report.

    Feed every event from the pbc JSONL stream via on_event(), then call
    generate_json() / generate_html() / write() after the run completes
    (or is interrupted — partial data is still valid).
    """

    def __init__(self) -> None:
        self._start = time.monotonic()
        # Keyed by label, one accumulator per distinct step -- NOT a single
        # "current step" buffer flushed on label change. A flush-on-change
        # design silently assumes steps never nest, which breaks the moment
        # one Progress.timedStep wraps another (e.g. runPass67's "Building
        # call graph" wraps "Taint classification"): the inner step's own
        # start event would flush the outer step's accumulated-so-far data
        # as a bogus all-dashes row, and the outer step's later end event
        # would then open a second, separate row instead of completing the
        # first. Keying by label instead means an event always updates its
        # own step's accumulator regardless of what other labels interleave
        # in between -- nesting, nested-with-a-gap, and the plain sequential
        # case all fall out of the same rule. dict preserves insertion
        # order, so the report still lists steps in first-seen order.
        self._steps_by_label: dict[str, _ReportStep] = {}
        self._phases: list[dict[str, Any]] = []
        self._warnings: list[str] = []
        # Phase A's concurrent per-file workers (PB.Pipeline.Runner's
        # mapConcurrently_ over workerLoopFiles) emit worker_start/
        # worker_done, not step/phase -- tracked separately so the timeline
        # can show what each worker was doing and when, not just Phase B's
        # sequential analysis passes.
        self._worker_open: dict[int, tuple[float | None, str]] = {}
        self._worker_intervals: list[_WorkerInterval] = []
        self._lock = threading.Lock()
        self._finished = False
        self._frozen_snapshot: dict[str, Any] | None = None
        self._seq = 0
        self._subscribers: list[queue.Queue] = []

    def on_event(self, event: dict) -> None:
        with self._lock:
            self._seq += 1
            tag = event.get("tag", "")
            if tag == "step":
                self._handle_step(event)
            elif tag == "phase":
                self._phases.append({
                    "name": event.get("name", ""),
                    "since_start_ms": event.get("since_start_ms"),
                })
            elif tag == "warning":
                self._warnings.append(event.get("message", ""))
            elif tag == "worker_start":
                worker = event.get("worker")
                if worker is not None:
                    self._worker_open[worker] = (event.get("since_start_ms"), event.get("file", ""))
            elif tag == "worker_done":
                worker = event.get("worker")
                if worker is not None:
                    start_since, file = self._worker_open.pop(worker, (event.get("since_start_ms"), event.get("file", "")))
                    if start_since is not None:
                        self._worker_intervals.append(_WorkerInterval(
                            worker=worker,
                            file=file,
                            start_since_start_ms=start_since,
                            end_since_start_ms=event.get("since_start_ms"),
                        ))
            if self._subscribers:
                snap = self._snapshot_locked()
                for q in self._subscribers:
                    try:
                        q.put_nowait(snap)
                    except Exception:  # noqa: BLE001 — slow subscriber, drop
                        pass

    def _handle_step(self, event: dict) -> None:
        label = event.get("label", "")
        if not label:
            return
        input_rows = event.get("input_rows") or {}
        derived_rows = event.get("derived_rows") or {}
        elapsed_ms = event.get("elapsed_ms")
        residency_mb = event.get("residency_mb")
        since_start_ms = event.get("since_start_ms")

        step = self._steps_by_label.get(label)
        if step is None:
            step = _ReportStep(label=label, start_since_start_ms=since_start_ms)
            self._steps_by_label[label] = step

        if input_rows:
            step.input_rows.update(input_rows)
        if elapsed_ms is not None:
            step.elapsed_ms = elapsed_ms
            if step.completed_seq is None:
                step.completed_seq = self._seq
        if derived_rows:
            step.derived_rows.update(derived_rows)
        if residency_mb is not None:
            if step.peak_residency_mb is None or residency_mb > step.peak_residency_mb:
                step.peak_residency_mb = residency_mb
        if since_start_ms is not None:
            step.end_since_start_ms = since_start_ms
        step.last_event_seq = self._seq

    @property
    def _steps(self) -> list[_ReportStep]:
        return list(self._steps_by_label.values())

    def _compute_elapsed_ms(self, now_ms: float) -> float:
        """Total elapsed time derived from step durations, not wall-clock time.

        Uses max(start + elapsed_ms) across completed steps.  Falls back to
        now_ms when steps are still in flight (live progress view).
        """
        in_flight = any(s.elapsed_ms is None for s in self._steps if s.start_since_start_ms is not None)
        completed_finishes = [
            s.start_since_start_ms + s.elapsed_ms
            for s in self._steps
            if s.completed_seq is not None and s.start_since_start_ms is not None and s.elapsed_ms is not None
        ]
        if completed_finishes and not in_flight:
            return float(max(completed_finishes))
        return round(now_ms, 1)

    def generate_json(self, *, now_ms: float | None = None) -> dict:
        with self._lock:
            fallback = round((time.monotonic() - self._start) * 1000, 1) if now_ms is None else now_ms
            total_ms = self._compute_elapsed_ms(fallback)
            return {
                "total_elapsed_ms": round(total_ms, 1) if isinstance(total_ms, float) else total_ms,
                "steps": [
                    {
                        "label": s.label,
                        "elapsed_ms": s.elapsed_ms,
                        "input_rows": s.input_rows,
                        "derived_rows": s.derived_rows,
                        "peak_residency_mb": s.peak_residency_mb,
                        "start_since_start_ms": s.start_since_start_ms,
                        "end_since_start_ms": self._effective_end(s.end_since_start_ms, s.elapsed_ms is None, now_ms),
                    }
                    for s in self._steps
                ],
                "phases": list(self._phases),
                "warnings": list(self._warnings),
                "phase_a_workers": [
                    {
                        "worker": iv.worker,
                        "file": iv.file,
                        "start_since_start_ms": iv.start_since_start_ms,
                        "end_since_start_ms": iv.end_since_start_ms,
                    }
                    for iv in self._effective_worker_intervals(now_ms)
                ],
            }

    def generate_html(self, *, now_ms: float | None = None) -> str:
        with self._lock:
            total_ms = (time.monotonic() - self._start) * 1000
            # After finish(), cap at the frozen elapsed so the HTML report
            # and its embedded SVG never show a duration beyond the actual run.
            if self._frozen_snapshot is not None:
                total_ms = min(total_ms, self._frozen_snapshot["elapsed_ms"])

            phases_html = (
                "<h2>Phases</h2><ul>"
                + "".join(f"<li>{html.escape(p['name'])}</li>" for p in self._phases)
                + "</ul>"
            ) if self._phases else ""

            warnings_html = (
                "<h2>Warnings</h2><ul class=\"warnings\">"
                + "".join(f"<li>{html.escape(w)}</li>" for w in self._warnings)
                + "</ul>"
            ) if self._warnings else ""

            rows_html = "".join(
                "<tr>"
                f"<td>{html.escape(s.label)}</td>"
                f"<td>{self._fmt_ms(s.elapsed_ms) if s.elapsed_ms is not None else '—'}</td>"
                f"<td>{self._fmt_rows(s.input_rows) if s.input_rows else '—'}</td>"
                f"<td>{self._fmt_rows(s.derived_rows) if s.derived_rows else '—'}</td>"
                f"<td>{self._fmt_res(s.peak_residency_mb) if s.peak_residency_mb is not None else '—'}</td>"
                "</tr>"
                for s in self._steps
            )
            table_html = (
                "<h2>Steps</h2>"
                "<table><thead><tr><th>Step</th><th>Duration</th><th>Input Rows</th>"
                "<th>Derived Rows</th><th>Peak RES</th></tr></thead>"
                f"<tbody>{rows_html}</tbody></table>"
            ) if self._steps else ""

            return _HTML_TEMPLATE.format(
                viz_root_css=VIZ_ROOT_CSS,
                total_elapsed=self._fmt_ms(total_ms),
                phases_html=phases_html,
                timeline_html=self._render_timeline_svg(now_ms=now_ms),
                table_html=table_html,
                warnings_html=warnings_html,
            )

    def finish(self) -> None:
        with self._lock:
            self._finished = True
            # Freeze the entire snapshot so it never changes after the job
            # completes.  Without this, _snapshot_locked recomputes from
            # time.monotonic() (advances forever) or from step data (can
            # change if late events arrive), causing the timeline to show
            # different durations on page reload.
            self._frozen_snapshot = self._snapshot_locked()
            subscribers = list(self._subscribers)
        for q in subscribers:
            try:
                q.put_nowait({"tag": "done"})
            except Exception:  # noqa: BLE001
                pass

    def subscribe(self, q: queue.Queue) -> None:
        with self._lock:
            self._subscribers.append(q)

    def unsubscribe(self, q: queue.Queue) -> None:
        with self._lock:
            self._subscribers = [s for s in self._subscribers if s is not q]

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            if self._frozen_snapshot is not None:
                return self._frozen_snapshot
            return self._snapshot_locked()

    def _snapshot_locked(self) -> dict[str, Any]:
        now_ms = (time.monotonic() - self._start) * 1000
        in_flight = [s for s in self._steps if s.start_since_start_ms is not None and s.elapsed_ms is None]
        current = max(in_flight, key=lambda s: s.last_event_seq) if in_flight else None
        current_start = current.start_since_start_ms if current is not None else None
        completed = sorted(
            [s for s in self._steps if s.completed_seq is not None],
            key=lambda s: s.completed_seq or 0,
        )
        elapsed_ms = self._compute_elapsed_ms(now_ms)
        return {
            "status": "complete" if self._finished else "running",
            "elapsed_ms": round(elapsed_ms, 1) if isinstance(elapsed_ms, float) else elapsed_ms,
            "timeline_html": self._render_timeline_svg(now_ms=now_ms),
            "steps": [
                {
                    "label": s.label,
                    "elapsed_ms": s.elapsed_ms,
                    "input_rows": s.input_rows,
                    "derived_rows": s.derived_rows,
                    "peak_residency_mb": s.peak_residency_mb,
                }
                for s in completed
            ],
            "current": {
                "label": current.label,
                "start_since_start_ms": current_start,
                "elapsed_ms": round(now_ms - current_start, 1) if current_start is not None else 0,
                "input_rows": current.input_rows,
                "derived_rows": current.derived_rows,
                "peak_residency_mb": current.peak_residency_mb,
            } if current is not None else None,
            "workers": [
                {
                    "worker": w,
                    "file": f,
                    "start_since_start_ms": s,
                    "elapsed_ms": round(now_ms - s, 1) if s is not None else None,
                }
                for w, (s, f) in sorted(self._worker_open.items())
            ],
        }

    @staticmethod
    def _effective_end(end: float | None, in_flight: bool, now_ms: float | None) -> float | None:
        return now_ms if (in_flight and now_ms is not None) else end

    def _effective_worker_intervals(self, now_ms: float | None) -> list[_WorkerInterval]:
        if now_ms is None:
            return self._worker_intervals
        result = list(self._worker_intervals)
        for w, (s, f) in self._worker_open.items():
            if s is not None and now_ms > s:
                result.append(_WorkerInterval(worker=w, file=f, start_since_start_ms=s, end_since_start_ms=now_ms))
        return result

    # Beyond this many distinct Phase A workers, per-worker lanes fold into
    # one aggregate "File parsing (Phase A)" lane -- keeps the chart's
    # height bounded on a many-core machine while still showing individual
    # worker contributions on the common case (a handful of workers).
    _MAX_WORKER_LANES = 16

    def _render_timeline_svg(self, *, now_ms: float | None = None, plot_width: float = 1200.0) -> str:
        """Swim-lane timeline positioned by each event's absolute
        since_start_ms offset rather than its own duration alone -- the only
        representation that stays meaningful once Phase A's concurrent
        per-file workers and every other sequential step contribute events
        to the same report. One lane per Phase A worker (or one aggregate
        lane past _MAX_WORKER_LANES), then one lane per step-kind category.

        plot_width controls the horizontal scale in pixels; zooming changes
        this value while keeping the label gutter and lane heights fixed.
        """
        steps_with_time = [s for s in self._steps if s.start_since_start_ms is not None]
        effective_workers = self._effective_worker_intervals(now_ms)
        worker_ids = sorted({iv.worker for iv in effective_workers})
        show_per_worker = 0 < len(worker_ids) <= self._MAX_WORKER_LANES

        def worker_lane(w: int) -> str:
            return f"Worker {w}" if show_per_worker else "File parsing (Phase A)"

        worker_lanes = (
            [worker_lane(w) for w in worker_ids] if show_per_worker
            else (["File parsing (Phase A)"] if effective_workers else [])
        )
        category_lanes = [k for k in _KIND_ORDER if any(_step_kind(s.label) == k for s in steps_with_time)]
        all_lanes = worker_lanes + category_lanes

        instants = [p["since_start_ms"] for p in self._phases if p.get("since_start_ms") is not None]
        for s in steps_with_time:
            instants.append(s.start_since_start_ms)
            if s.end_since_start_ms is not None:
                instants.append(s.end_since_start_ms)
        for iv in effective_workers:
            instants.append(iv.start_since_start_ms)
            if iv.end_since_start_ms is not None:
                instants.append(iv.end_since_start_ms)
        if now_ms is not None:
            instants.append(now_ms)
        if not instants or not all_lanes:
            return ""
        total_span_ms = max(instants)
        if total_span_ms <= 0:
            return ""

        # Dedicated label column, like a real Gantt chart's resource axis --
        # lane labels live here, never in the plot area itself, so a bar
        # starting near t=0 (a real, common case: Phase A workers and
        # "Scanning source directory" both start at/near the beginning)
        # can never paint over its own lane's label.
        label_gutter = 200.0
        total_width = label_gutter + plot_width
        scale = plot_width / total_span_ms

        lane_index = {lbl: i for i, lbl in enumerate(all_lanes)}
        lane_h = 22
        lane_gap = 2
        top_pad = 24
        axis_h = 20
        height = top_pad + len(all_lanes) * (lane_h + lane_gap) + axis_h

        parts = [
            f'<svg viewBox="0 0 {total_width:.0f} {height:.0f}" width="{total_width:.0f}" '
            f'height="{height:.0f}" xmlns="http://www.w3.org/2000/svg" '
            'role="img" aria-label="Pipeline timeline">'
        ]

        # Unaccounted-time bands: any span not covered by a worker interval
        # or a step, above a noise threshold -- a generic net for whatever
        # instrumentation gap turns up next, rather than hand-instrumenting
        # every one found today and hoping that's the last of them. Drawn
        # first so every real bar renders on top of it.
        accounted: list[tuple[float, float]] = [
            (iv.start_since_start_ms, iv.end_since_start_ms if iv.end_since_start_ms is not None else iv.start_since_start_ms)
            for iv in effective_workers
        ]
        for s in steps_with_time:
            start = s.start_since_start_ms
            assert start is not None  # guaranteed by the steps_with_time filter above
            eff_end = self._effective_end(s.end_since_start_ms, s.elapsed_ms is None, now_ms)
            accounted.append((start, eff_end if eff_end is not None else start))
        for gap_start, gap_end in _find_gaps(accounted, total_span_ms):
            x = label_gutter + gap_start * scale
            w = max(1.5, (gap_end - gap_start) * scale)
            parts.append(
                f'<rect x="{x:.1f}" y="{top_pad - 4:.1f}" width="{w:.1f}" '
                f'height="{height - axis_h - top_pad + 4:.1f}" class="gap">'
                f"<title>Unaccounted time — {self._fmt_ms(gap_end - gap_start)}</title></rect>"
            )

        # Phase boundaries: vertical dashed guides with a label at the top.
        for p in self._phases:
            since = p.get("since_start_ms")
            if since is None:
                continue
            x = label_gutter + since * scale
            parts.append(
                f'<line x1="{x:.1f}" y1="{top_pad - 4:.1f}" x2="{x:.1f}" '
                f'y2="{height - axis_h:.1f}" class="phase-guide"/>'
            )
            parts.append(f'<text x="{x + 3:.1f}" y="{top_pad - 8:.1f}" class="phase-label">'
                         f'{html.escape(p["name"])}</text>')

        # Lane label (in the dedicated gutter) + baseline gridline (in the
        # plot area only) per lane.
        for lbl, i in lane_index.items():
            y = top_pad + i * (lane_h + lane_gap)
            parts.append(f'<line x1="{label_gutter:.0f}" y1="{y + lane_h:.1f}" '
                         f'x2="{total_width:.0f}" y2="{y + lane_h:.1f}" class="lane-grid"/>')
            parts.append(f'<text x="4" y="{y + lane_h - 6:.1f}" class="lane-label">'
                         f'{html.escape(lbl)}</text>')

        def render_bar(lane_label: str, start: float, end: float | None, series: int, tooltip: str) -> str:
            y = top_pad + lane_index[lane_label] * (lane_h + lane_gap)
            end_ = end if end is not None else start
            x = label_gutter + start * scale
            w = max(1.5, (end_ - start) * scale)
            return (
                f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{lane_h - 4:.1f}" '
                f'rx="4" class="bar series-{series}"><title>{html.escape(tooltip)}</title></rect>'
            )

        # One bar per Phase A file-processing interval, in its worker's lane
        # (or the aggregate lane once there are too many workers to show
        # individually).
        for iv in effective_workers:
            fname = iv.file.rsplit("/", 1)[-1] if iv.file else "?"
            parts.append(render_bar(
                worker_lane(iv.worker), iv.start_since_start_ms, iv.end_since_start_ms,
                series=6, tooltip=f"Worker {iv.worker}: {fname}",
            ))

        # One bar per step, in its category's lane.
        for s in steps_with_time:
            kind = _step_kind(s.label)
            start = s.start_since_start_ms
            assert start is not None  # guaranteed by the steps_with_time filter above
            dur = self._fmt_ms(s.elapsed_ms) if s.elapsed_ms is not None else "still running"
            bar_end = self._effective_end(s.end_since_start_ms, s.elapsed_ms is None, now_ms)
            parts.append(render_bar(
                kind, start, bar_end,
                series=_KIND_ORDER.index(kind) + 1, tooltip=f"{s.label} — {dur}",
            ))

        # Time axis: a handful of evenly-spaced ticks along the bottom.
        n_ticks = 6
        axis_y = height - axis_h + 12
        for i in range(n_ticks + 1):
            t_ms = total_span_ms * i / n_ticks
            x = label_gutter + t_ms * scale
            parts.append(f'<line x1="{x:.1f}" y1="{axis_y - 12:.1f}" x2="{x:.1f}" '
                         f'y2="{axis_y - 6:.1f}" class="lane-grid"/>')
            parts.append(f'<text x="{x:.1f}" y="{axis_y + 6:.1f}" class="axis-tick">'
                         f'{self._fmt_ms(t_ms)}</text>')

        parts.append("</svg>")

        legend_items = [
            f'<span class="legend-item"><span class="swatch series-{_KIND_ORDER.index(k) + 1}"></span>'
            f"{html.escape(k)}</span>"
            for k in category_lanes
        ]
        if effective_workers:
            legend_items.insert(
                0,
                '<span class="legend-item"><span class="swatch series-6"></span>'
                "File parsing (Phase A)</span>",
            )
        legend = "".join(legend_items)

        return (
            '<h2>Timeline</h2><div class="timeline">'
            + "".join(parts)
            + f'</div><div class="legend">{legend}</div>'
        )

    def write(self, path: str) -> None:
        from pathlib import Path

        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.with_suffix(".json").write_text(json.dumps(self.generate_json(), indent=2))
        p.with_suffix(".html").write_text(self.generate_html())

    def generate_timeline_svg(self, *, zoom: float = 1.0) -> str:
        """Generate just the timeline SVG at a given zoom level.

        zoom=1.0 is the default 1200px plot width; zoom=2.0 doubles it, etc.
        """
        with self._lock:
            now_ms = (time.monotonic() - self._start) * 1000
            # After finish(), cap now_ms at the frozen elapsed so the SVG
            # time axis never extends beyond the actual step data.
            if self._frozen_snapshot is not None:
                now_ms = min(now_ms, self._frozen_snapshot["elapsed_ms"])
            pw = 1200.0 * zoom
            svg = self._render_timeline_svg(now_ms=now_ms, plot_width=pw)
            if not svg:
                return ""
            # Wrap in the same viz-root structure the frontend expects
            return (
                '<div class="viz-root">'
                f'<div class="timeline">{svg}</div>'
                '</div>'
            )

    @staticmethod
    def _fmt_ms(ms: float) -> str:
        secs = ms / 1000
        if secs < 60:
            return f"{secs:.1f}s"
        mins = int(secs // 60)
        secs_rem = secs - mins * 60
        return f"{mins}m{secs_rem:.0f}s"

    @staticmethod
    def _fmt_rows(rows: dict[str, int]) -> str:
        total = sum(rows.values())
        if total >= 1_000_000:
            return f"{total / 1_000_000:.1f}M"
        if total >= 1_000:
            return f"{total / 1_000:.1f}K"
        return str(total)

    @staticmethod
    def _fmt_res(mb: float) -> str:
        if mb >= 1024:
            return f"{mb / 1024:.1f}GB"
        return f"{mb:.0f}MB"


class _LiveRunnerProgress:
    """Drives a Rich Live display from pbc JSONL progress events.

    Layout during Phase A (parsing):
        ⠸ Parsing & indexing  [████░░░░░░]  423/1051  12.3s  ⚠ 3 errors
          ├ Worker 0  w_order.srw
          ├ Worker 1  w_customer.srw
          └ Worker 2  (idle)

    Layout during Phase B (link analysis):
        ⠸ Link analysis — Resolving types  8.2s
    """

    def __init__(self, console) -> None:
        self._console = console
        self._lock = threading.Lock()
        self._live: Any = None

        self._total = 0
        self._done = 0
        self._errors = 0
        self._phase_label = "Starting"
        self._workers: dict[int, str | None] = {}
        self._step = ""
        self._phase_name = ""
        self._start = time.monotonic()

        # Step history tracking (mirrors _LiveAnalyzeProgress.times pattern)
        self._current_label: str = ""
        self._current_start: float = 0.0
        self._current_elapsed_ms: float | None = None
        self._current_input_rows: dict[str, int] = {}
        self._current_derived_rows: dict[str, int] = {}
        self._current_residency_mb: float | None = None
        self._step_history: list[_StepInfo] = []
        self._max_history = 12

    @property
    def parsed_count(self) -> int:
        return self._done

    def on_event(self, event: dict) -> None:
        tag = event.get("tag", "")
        with self._lock:
            if tag == "total":
                self._total = event["n"]
            elif tag == "phase":
                name = event["name"]
                self._phase_name = name
                if name in ("A", "A0"):
                    self._done = 0  # reset counter for each parsing phase
                if name == "A0":
                    # Doubles as the umbrella label once parsing finishes and
                    # rendering falls through to the step-label branch (see
                    # the self._done < self._total check in _render) -- must
                    # read sensibly as a prefix to a named step ("Parsing —
                    # Building workspace type env"), not just as the bar's
                    # phase name.
                    self._phase_label = "Parsing"
                    self._total = event.get("total", self._total)
                    self._workers = {}
                    self._step = ""
                elif name == "A":
                    self._phase_label = "Parsing & indexing"
                    self._total = event.get("total", self._total)
                    nw = event.get("workers", 1)
                    self._workers = {k: None for k in range(nw)}
                    self._step = ""
                elif name == "B":
                    self._phase_label = "Link analysis"
                    self._workers = {}
                    self._step = ""
            elif tag == "file_done":
                self._done += 1
            elif tag == "worker_start":
                self._workers[event["worker"]] = os.path.basename(event["file"])
            elif tag == "worker_done":
                self._workers[event["worker"]] = None
                self._done += 1
                if not event.get("ok", True):
                    self._errors += 1
            elif tag == "step":
                label = event.get("label", "")
                elapsed_ms = event.get("elapsed_ms")
                input_rows = event.get("input_rows") or {}
                derived_rows = event.get("derived_rows") or {}
                residency_mb = event.get("residency_mb")

                # Detect step boundary: a new label means the previous step
                # completed — push it to history.
                if label and label != self._current_label:
                    if self._current_label:
                        self._step_history.append(_StepInfo(
                            label=self._current_label,
                            elapsed_ms=self._current_elapsed_ms,
                            input_rows=self._current_input_rows,
                            derived_rows=self._current_derived_rows,
                            residency_mb=self._current_residency_mb,
                        ))
                        if len(self._step_history) > self._max_history:
                            self._step_history = self._step_history[-self._max_history:]
                    self._current_label = label
                    self._current_start = time.monotonic()
                    self._current_elapsed_ms = None
                    self._current_input_rows = {}
                    self._current_derived_rows = {}
                    self._current_residency_mb = None

                # Inherit input_rows from start event
                if input_rows:
                    self._current_input_rows.update(input_rows)

                # Update elapsed/residency/rows from end/heartbeat events
                if elapsed_ms is not None:
                    self._current_elapsed_ms = elapsed_ms
                if derived_rows:
                    self._current_derived_rows.update(derived_rows)
                if residency_mb is not None:
                    self._current_residency_mb = residency_mb

                self._step = label
            elif tag == "ddl_loaded":
                for line in _format_ddl_loaded(event):
                    self._console.print(line)
            elif tag == "warning":
                self._console.print(_format_warning(event))
        self._refresh()

    def _refresh(self) -> None:
        if self._live is not None:
            self._live.update(self._render())

    def _render(self):
        from rich.console import Group
        from rich.text import Text

        elapsed = time.monotonic() - self._start
        elapsed_str = f"{elapsed:.1f}s"

        # ── main progress line ──────────────────────────────────────────────
        # Once every file's file_done has landed (self._done >= self._total),
        # fall through to the step-label branch below even though no new
        # "phase" event has fired yet (Phase B's "phase" event only arrives
        # once link analysis starts) -- pbc runs several more named steps
        # after parsing finishes (building the workspace type env, the
        # control index, the type-check workspace; see runModeDb) before
        # Phase B begins, and without this check the bar stayed frozen at
        # N/N for their entire duration with no indication of what was
        # actually running (doc/plan/187-perf-hotspots.md sec16 -- this is
        # the reporter-side half of that fix, not just a display tweak: the
        # bar looked "done" while pbc was still doing real, now-labeled work).
        if self._phase_name in ("A", "A0") and self._total > 0 and self._done < self._total:
            pct = self._done / self._total
            bar_w = 24
            filled = round(bar_w * pct)
            bar = "█" * filled + "░" * (bar_w - filled)
            line = Text()
            line.append(f"{self._phase_label}", style="bold")
            line.append(f"  [{bar}]  {self._done}/{self._total}  {elapsed_str}")
            if self._errors:
                line.append(f"  ⚠ {self._errors} error(s)", style="red")
        else:
            label = f"{self._phase_label}"
            if self._current_label:
                label += f" — {self._current_label}"
                step_elapsed = self._format_current_elapsed()
                label += f"  {step_elapsed}"
                res = self._current_residency_mb
                if res is not None:
                    if res >= 1000:
                        label += f", {res / 1024:.1f}GB RES"
                    else:
                        label += f", {res:.0f}MB RES"
            line = Text()
            line.append(label, style="bold")
            line.append(f"  {elapsed_str}")

        rows: list = [line]

        # ── step history (last N completed steps) ───────────────────────────
        for info in self._step_history:
            rows.append(Text.from_markup(
                f"  [dim]  {self._format_step_summary(info)}[/dim]"
            ))

        # ── per-worker rows ─────────────────────────────────────────────────
        if self._workers:
            items = sorted(self._workers.items())
            for i, (wid, fname) in enumerate(items):
                is_last = i == len(items) - 1
                connector = "└" if is_last else "├"
                if fname:
                    rows.append(
                        Text.from_markup(
                            f"  [dim]{connector} Worker {wid}[/dim]  [cyan]{fname}[/cyan]"
                        )
                    )
                else:
                    rows.append(
                        Text.from_markup(f"  [dim]{connector} Worker {wid}  idle[/dim]")
                    )

        return Group(*rows)

    def _format_step_summary(self, info: _StepInfo) -> str:
        parts = [info.label]
        if info.elapsed_ms is not None:
            parts.append(self._format_elapsed_ms(info.elapsed_ms))
        row_str = self._format_row_counts(info.input_rows, info.derived_rows)
        if row_str:
            parts.append(row_str)
        return " — ".join(parts)

    def _format_current_elapsed(self) -> str:
        if self._current_elapsed_ms is not None:
            return self._format_elapsed_ms(self._current_elapsed_ms)
        # No end event yet — show live elapsed from start
        live_ms = (time.monotonic() - self._current_start) * 1000
        return f"running {self._format_elapsed_ms(live_ms)}"

    @staticmethod
    def _format_elapsed_ms(ms: float) -> str:
        secs = ms / 1000
        if secs < 60:
            return f"{secs:.1f}s"
        mins = int(secs // 60)
        secs_rem = secs - mins * 60
        return f"{mins}m{secs_rem:.0f}s"

    @staticmethod
    def _format_row_counts(
        input_rows: dict[str, int], derived_rows: dict[str, int]
    ) -> str:
        def _fmt(n: int) -> str:
            if n >= 1_000_000:
                return f"{n / 1_000_000:.1f}M"
            if n >= 1_000:
                return f"{n / 1_000:.1f}K"
            return str(n)

        if input_rows:
            if len(input_rows) == 1:
                parts_str = f"{_fmt(next(iter(input_rows.values())))} in"
            else:
                parts_str = f"{_fmt(sum(input_rows.values()))} in"
        else:
            parts_str = ""
        if derived_rows:
            if len(derived_rows) == 1:
                out_str = f"{_fmt(next(iter(derived_rows.values())))} out"
            else:
                out_str = f"{_fmt(sum(derived_rows.values()))} out"
        else:
            out_str = ""
        if parts_str and out_str:
            return f"{parts_str} / {out_str}"
        return parts_str or out_str


class _RecordingRunnerProgress:
    def __init__(self, events: list[dict]) -> None:
        self._events = events
        self.error_count = 0
        self._parsed_count = 0

    @property
    def parsed_count(self) -> int:
        return self._parsed_count

    def on_event(self, event: dict) -> None:
        self._events.append({"type": "runner_event", **event})
        tag = event.get("tag")
        if tag in ("file_done", "worker_done"):
            self._parsed_count += 1
        if tag == "done":
            self.error_count = event.get("errors", 0)


# ── Reporter protocol ──────────────────────────────────────────────────────────


class Reporter(Protocol):
    def building(self) -> None: ...
    def status(self, msg: str) -> AbstractContextManager[None]: ...
    def extracting_progress(self, total: int) -> AbstractContextManager[ExtractProgress]: ...
    def parse_progress(self, total: int, label: str) -> AbstractContextManager[ParseProgress]: ...
    def indexing_step(self) -> AbstractContextManager[Callable[[int], None]]: ...
    def analyze_progress(self) -> AbstractContextManager[AnalyzeProgress]: ...
    def runner_progress(self) -> AbstractContextManager[RunnerProgress]: ...
    def done(
        self,
        *,
        parsed: int,
        errors: int,
        rows: int | None = None,
        diff: FileDiff | None = None,
        sql_parse_failures: int | None = None,
    ) -> None: ...


# ── LiveReporter ───────────────────────────────────────────────────────────────


class LiveReporter:
    def __init__(self, console=None) -> None:
        from rich.console import Console

        self._c = console or Console(stderr=True)

    def building(self) -> None:
        self._c.print("[bold]Building pbc...[/bold]", highlight=False)

    @contextmanager
    def status(self, msg: str) -> Iterator[None]:
        with self._c.status(f"[dim]{msg}[/dim]"):
            yield

    @contextmanager
    def extracting_progress(self, total: int) -> Iterator[_LiveExtractProgress]:
        from rich.progress import (
            BarColumn,
            MofNCompleteColumn,
            Progress,
            SpinnerColumn,
            TextColumn,
            TimeElapsedColumn,
        )

        with Progress(
            SpinnerColumn(finished_text="[green]✓[/green]"),
            TextColumn("[bold]{task.description}"),
            BarColumn(),
            MofNCompleteColumn(),
            TimeElapsedColumn(),
            console=self._c,
        ) as progress:
            task = progress.add_task("Extracting PBLs", total=total)
            yield _LiveExtractProgress(progress, task)

    @contextmanager
    def parse_progress(self, total: int, label: str) -> Iterator[_LiveParseProgress]:
        from rich.progress import (
            BarColumn,
            MofNCompleteColumn,
            Progress,
            SpinnerColumn,
            TextColumn,
            TimeElapsedColumn,
        )

        with Progress(
            SpinnerColumn(finished_text="[green]✓[/green]"),
            TextColumn("[bold]{task.description}[/bold]"),
            BarColumn(),
            MofNCompleteColumn(),
            TimeElapsedColumn(),
            TextColumn("{task.fields[err_str]}"),
            console=self._c,
        ) as progress:
            task = progress.add_task(label, total=total, err_str="")
            yield _LiveParseProgress(progress, task)

    @contextmanager
    def indexing_step(self) -> Iterator[Callable[[int], None]]:
        from rich.progress import Progress, SpinnerColumn, TextColumn, TimeElapsedColumn

        total_rows = 0
        with Progress(
            SpinnerColumn(finished_text="[green]✓[/green]"),
            TextColumn("[bold]{task.description}[/bold]"),
            TimeElapsedColumn(),
            console=self._c,
        ) as progress:
            task = progress.add_task("[1/2] Indexing", total=None)

            def advance(n: int) -> None:
                nonlocal total_rows
                total_rows += n
                progress.update(task, description=f"[1/2] Indexing  {total_rows:,} rows")

            yield advance
            progress.update(task, total=1, completed=1, description=f"[1/2] Indexing  {total_rows:,} rows")

    @contextmanager
    def analyze_progress(self) -> Iterator[_LiveAnalyzeProgress]:
        from rich.progress import (
            Progress,
            SpinnerColumn,
            TextColumn,
            TimeElapsedColumn,
        )

        with Progress(
            SpinnerColumn(finished_text="[green]✓[/green]"),
            TextColumn("[bold]{task.description}"),
            TimeElapsedColumn(),
            console=self._c,
        ) as progress:
            task = progress.add_task("[2/2] analyzing", total=None)
            prog = _LiveAnalyzeProgress(progress, task)
            yield prog
            prog._finish()
            progress.update(task, total=1, completed=1)
        for name, elapsed in prog.times:
            self._c.print(f"  [dim]{name:<28} {elapsed:.1f}s[/dim]")

    @contextmanager
    def runner_progress(self) -> Iterator[_LiveRunnerProgress]:
        from rich.live import Live
        from rich.text import Text

        prog = _LiveRunnerProgress(self._c)
        stop_ticker = threading.Event()

        def _ticker() -> None:
            while not stop_ticker.wait(0.1):
                prog._refresh()

        ticker = threading.Thread(target=_ticker, daemon=True)

        # Initial placeholder shown before the first event arrives
        with Live(
            Text.from_markup("[dim]Starting pbc…[/dim]"),
            console=self._c,
            refresh_per_second=12,
            transient=False,
        ) as live:
            prog._live = live
            ticker.start()
            try:
                yield prog
            finally:
                stop_ticker.set()
                ticker.join(timeout=0.5)
        # Print a compact summary line once Live exits
        elapsed = time.monotonic() - prog._start
        if prog._errors:
            self._c.print(
                f"[green]✓[/green] Indexed {prog._done}/{prog._total} files"
                f"  [red]⚠ {prog._errors} error(s)[/red]  {elapsed:.1f}s"
            )
        else:
            self._c.print(
                f"[green]✓[/green] Indexed {prog._done}/{prog._total} files  {elapsed:.1f}s"
            )

    def done(
        self,
        *,
        parsed: int,
        errors: int,
        rows: int | None = None,
        diff: FileDiff | None = None,
        sql_parse_failures: int | None = None,
    ) -> None:
        parts: list[str] = []
        no_source_changes = diff is not None and not diff.new and not diff.changed and not diff.deleted
        if diff is not None:
            if diff.new:
                parts.append(f"{len(diff.new)} new")
            if diff.changed:
                parts.append(f"{len(diff.changed)} changed")
            if diff.deleted:
                parts.append(f"[dim]{len(diff.deleted)} deleted[/dim]")
            if not parts and diff.unchanged:
                parts.append(f"[dim]{len(diff.unchanged)} unchanged[/dim]")
        else:
            parts.append(f"{parsed} parsed")
        if rows is not None:
            parts.append(f"{rows:,} rows indexed")
        summary = " · ".join(parts) if parts else "no changes"
        if errors:
            self._c.print(f"[yellow]Done[/yellow] ({summary}) · [red]⚠ {errors} parse error(s)[/red]")
        else:
            self._c.print(f"[green]Done[/green] ({summary})")
        if no_source_changes:
            self._c.print(
                "[dim]No source files changed, so nothing was re-extracted. If you changed ingestion/"
                "extraction logic (not source), run with --reset to rebuild all rows.[/dim]"
            )
        if sql_parse_failures:
            self._c.print(
                f"[yellow]⚠ {sql_parse_failures} SQL statement(s) failed to parse[/yellow] "
                "(see sql_statements WHERE NOT parse_ok)"
            )


# ── RecordingReporter (tests) ──────────────────────────────────────────────────


@dataclass
class RecordingReporter:
    """Test double: no rich dependency; all events are JSON-serialisable dicts."""

    events: list[dict] = field(default_factory=list)

    def building(self) -> None:
        self.events.append({"type": "building"})

    @contextmanager
    def status(self, msg: str) -> Iterator[None]:
        self.events.append({"type": "status", "msg": msg})
        yield

    @contextmanager
    def extracting_progress(self, total: int) -> Iterator[_RecordingExtractProgress]:
        self.events.append({"type": "extracting_start", "total": total})
        prog = _RecordingExtractProgress(self.events)
        yield prog
        self.events.append({"type": "extracting_end"})

    @contextmanager
    def parse_progress(self, total: int, label: str) -> Iterator[_RecordingParseProgress]:
        self.events.append({"type": "parse_start", "total": total, "label": label})
        prog = _RecordingParseProgress(self.events)
        yield prog
        self.events.append({"type": "parse_end", "errors": prog.error_count})

    @contextmanager
    def indexing_step(self) -> Iterator[Callable[[int], None]]:
        self.events.append({"type": "indexing_start"})

        def advance(n: int) -> None:
            self.events.append({"type": "index_chunk", "n": n})

        yield advance
        self.events.append({"type": "indexing_end"})

    @contextmanager
    def analyze_progress(self) -> Iterator[_RecordingAnalyzeProgress]:
        self.events.append({"type": "analyze_start"})
        prog = _RecordingAnalyzeProgress(self.events)
        yield prog
        self.events.append({"type": "analyze_end"})

    @contextmanager
    def runner_progress(self) -> Iterator[_RecordingRunnerProgress]:
        self.events.append({"type": "runner_start"})
        prog = _RecordingRunnerProgress(self.events)
        yield prog
        self.events.append({"type": "runner_end", "errors": prog.error_count})

    def done(
        self,
        *,
        parsed: int,
        errors: int,
        rows: int | None = None,
        diff: FileDiff | None = None,
        sql_parse_failures: int | None = None,
    ) -> None:
        self.events.append(
            {
                "type": "done",
                "parsed": parsed,
                "errors": errors,
                "rows": rows,
                "sql_parse_failures": sql_parse_failures,
                "diff": {
                    "new": len(diff.new),
                    "changed": len(diff.changed),
                    "deleted": len(diff.deleted),
                }
                if diff is not None
                else None,
            }
        )
