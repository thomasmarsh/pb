"""Unified output protocol for pipeline operations.

Two implementations:
  LiveReporter        — rich-backed; for CLI use
  RecordingReporter   — accumulates JSON-serialisable events; for tests
"""

from __future__ import annotations

import os
import threading
import time
from collections.abc import Callable, Iterator
from contextlib import AbstractContextManager, contextmanager
from dataclasses import dataclass, field
from typing import Any, Protocol

from pb_cli.core.state import FileDiff

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
        from pb_cli.shell.env import env

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
    def on_event(self, event: dict) -> None: ...


class _LiveRunnerProgress:
    """Drives a Rich Live display from pb-runner JSONL progress events.

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

    def on_event(self, event: dict) -> None:
        tag = event.get("tag", "")
        with self._lock:
            if tag == "total":
                self._total = event["n"]
            elif tag == "phase":
                name = event["name"]
                self._phase_name = name
                self._done = 0  # reset counter for each phase
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
                self._step = event["label"]
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
            if self._step:
                label += f" — {self._step}"
            line = Text()
            line.append(label, style="bold")
            line.append(f"  {elapsed_str}")

        rows: list = [line]

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


class _RecordingRunnerProgress:
    def __init__(self, events: list[dict]) -> None:
        self._events = events
        self.error_count = 0

    def on_event(self, event: dict) -> None:
        self._events.append({"type": "runner_event", **event})
        if event.get("tag") == "done":
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
        self._c.print("[bold]Building pb-runner...[/bold]", highlight=False)

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
            Text.from_markup("[dim]Starting pb-runner…[/dim]"),
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
