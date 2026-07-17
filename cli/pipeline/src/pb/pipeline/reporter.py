"""Unified output protocol for pipeline operations.

Two implementations:
  LiveReporter        — rich-backed; for CLI use
  RecordingReporter   — accumulates JSON-serialisable events; for tests
"""

from __future__ import annotations

import json
import os
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
    edb_rows: dict[str, int] = field(default_factory=dict)
    idb_rows: dict[str, int] = field(default_factory=dict)
    residency_mb: float | None = None


@dataclass
class _ReportStep:
    """One step in the diagnostics report."""

    label: str
    elapsed_ms: float | None = None
    edb_rows: dict[str, int] = field(default_factory=dict)
    idb_rows: dict[str, int] = field(default_factory=dict)
    peak_residency_mb: float | None = None


class DiagnosticsCollector:
    """Accumulates pipeline events and generates a post-run diagnostics report.

    Feed every event from the pbc JSONL stream via on_event(), then call
    generate_json() / generate_markdown() / write() after the run completes
    (or is interrupted — partial data is still valid).
    """

    def __init__(self) -> None:
        self._start = time.monotonic()
        self._steps: list[_ReportStep] = []
        self._phases: list[dict[str, Any]] = []
        self._warnings: list[str] = []
        # Current step being accumulated
        self._cur_label: str = ""
        self._cur_edb: dict[str, int] = {}
        self._cur_idb: dict[str, int] = {}
        self._cur_elapsed_ms: float | None = None
        self._cur_peak_res: float | None = None

    def on_event(self, event: dict) -> None:
        tag = event.get("tag", "")
        if tag == "step":
            self._handle_step(event)
        elif tag == "phase":
            self._phases.append({"name": event.get("name", "")})
        elif tag == "warning":
            self._warnings.append(event.get("message", ""))

    def _handle_step(self, event: dict) -> None:
        label = event.get("label", "")
        edb_rows = event.get("edb_rows") or {}
        idb_rows = event.get("idb_rows") or {}
        elapsed_ms = event.get("elapsed_ms")
        residency_mb = event.get("residency_mb")

        # New label means previous step completed — flush it
        if label and label != self._cur_label:
            self._flush_step()
            self._cur_label = label
            self._cur_edb = {}
            self._cur_idb = {}
            self._cur_elapsed_ms = None
            self._cur_peak_res = None

        if edb_rows:
            self._cur_edb.update(edb_rows)
        if elapsed_ms is not None:
            self._cur_elapsed_ms = elapsed_ms
        if idb_rows:
            self._cur_idb.update(idb_rows)
        if residency_mb is not None:
            if self._cur_peak_res is None or residency_mb > self._cur_peak_res:
                self._cur_peak_res = residency_mb

    def _flush_step(self) -> None:
        if not self._cur_label:
            return
        self._steps.append(_ReportStep(
            label=self._cur_label,
            elapsed_ms=self._cur_elapsed_ms,
            edb_rows=dict(self._cur_edb),
            idb_rows=dict(self._cur_idb),
            peak_residency_mb=self._cur_peak_res,
        ))

    def generate_json(self) -> dict:
        self._flush_step()
        total_ms = (time.monotonic() - self._start) * 1000
        return {
            "total_elapsed_ms": round(total_ms, 1),
            "steps": [
                {
                    "label": s.label,
                    "elapsed_ms": s.elapsed_ms,
                    "edb_rows": s.edb_rows,
                    "idb_rows": s.idb_rows,
                    "peak_residency_mb": s.peak_residency_mb,
                }
                for s in self._steps
            ],
            "phases": list(self._phases),
            "warnings": list(self._warnings),
        }

    def generate_markdown(self) -> str:
        self._flush_step()
        total_ms = (time.monotonic() - self._start) * 1000
        lines = [
            "# Pipeline Diagnostics Report",
            "",
            f"**Total elapsed:** {self._fmt_ms(total_ms)}",
            "",
        ]

        if self._phases:
            lines.append("## Phases")
            lines.append("")
            for p in self._phases:
                lines.append(f"- {p['name']}")
            lines.append("")

        if self._steps:
            lines.append("## Steps")
            lines.append("")
            lines.append("| Step | Duration | EDB Rows | IDB Rows | Peak RES |")
            lines.append("|------|----------|----------|----------|----------|")
            for s in self._steps:
                dur = self._fmt_ms(s.elapsed_ms) if s.elapsed_ms is not None else "—"
                edb = self._fmt_rows(s.edb_rows) if s.edb_rows else "—"
                idb = self._fmt_rows(s.idb_rows) if s.idb_rows else "—"
                res = self._fmt_res(s.peak_residency_mb) if s.peak_residency_mb is not None else "—"
                lines.append(f"| {s.label} | {dur} | {edb} | {idb} | {res} |")
            lines.append("")

        if self._warnings:
            lines.append("## Warnings")
            lines.append("")
            for w in self._warnings:
                lines.append(f"- {w}")
            lines.append("")

        return "\n".join(lines)

    def write(self, path: str) -> None:
        from pathlib import Path

        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.with_suffix(".json").write_text(json.dumps(self.generate_json(), indent=2))
        p.with_suffix(".md").write_text(self.generate_markdown())

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
        self._current_edb_rows: dict[str, int] = {}
        self._current_idb_rows: dict[str, int] = {}
        self._current_residency_mb: float | None = None
        self._step_history: list[_StepInfo] = []
        self._max_history = 6

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
                    self._phase_label = "Building type env"
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
                edb_rows = event.get("edb_rows") or {}
                idb_rows = event.get("idb_rows") or {}
                residency_mb = event.get("residency_mb")

                # Detect step boundary: a new label means the previous step
                # completed — push it to history.
                if label and label != self._current_label:
                    if self._current_label:
                        self._step_history.append(_StepInfo(
                            label=self._current_label,
                            elapsed_ms=self._current_elapsed_ms,
                            edb_rows=self._current_edb_rows,
                            idb_rows=self._current_idb_rows,
                            residency_mb=self._current_residency_mb,
                        ))
                        if len(self._step_history) > self._max_history:
                            self._step_history = self._step_history[-self._max_history:]
                    self._current_label = label
                    self._current_start = time.monotonic()
                    self._current_elapsed_ms = None
                    self._current_edb_rows = {}
                    self._current_idb_rows = {}
                    self._current_residency_mb = None

                # Inherit edb_rows from start event
                if edb_rows:
                    self._current_edb_rows.update(edb_rows)

                # Update elapsed/residency/rows from end/heartbeat events
                if elapsed_ms is not None:
                    self._current_elapsed_ms = elapsed_ms
                if idb_rows:
                    self._current_idb_rows.update(idb_rows)
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
        if self._phase_name in ("A", "A0") and self._total > 0:
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
        row_str = self._format_row_counts(info.edb_rows, info.idb_rows)
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
        edb_rows: dict[str, int], idb_rows: dict[str, int]
    ) -> str:
        def _fmt(n: int) -> str:
            if n >= 1_000_000:
                return f"{n / 1_000_000:.1f}M"
            if n >= 1_000:
                return f"{n / 1_000:.1f}K"
            return str(n)

        if edb_rows:
            if len(edb_rows) == 1:
                parts_str = f"{_fmt(next(iter(edb_rows.values())))} in"
            else:
                parts_str = f"{_fmt(sum(edb_rows.values()))} in"
        else:
            parts_str = ""
        if idb_rows:
            if len(idb_rows) == 1:
                out_str = f"{_fmt(next(iter(idb_rows.values())))} out"
            else:
                out_str = f"{_fmt(sum(idb_rows.values()))} out"
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
