"""Unified output protocol for pipeline operations.

Two implementations:
  LiveReporter        — rich-backed; for CLI use
  RecordingReporter   — accumulates JSON-serialisable events; for tests
"""
from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass, field
from typing import Iterator, Protocol

from pbtools.state import FileDiff


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
        from pbtools.parse import render_error
        self.error_count += 1
        self._progress.update(self._task, err_str=f'[red]⚠ {self.error_count} errors[/red]')
        self._progress.console.print(render_error(obj))


class _RecordingParseProgress:
    def __init__(self, events: list[dict]) -> None:
        self._events = events
        self.error_count = 0

    def advance(self) -> None:
        self._events.append({'type': 'parse_advance'})

    def on_error(self, obj: dict) -> None:
        self.error_count += 1
        self._events.append({'type': 'parse_error', 'file': obj.get('file'), 'error': obj.get('error')})


# ── AnalyzeProgress ────────────────────────────────────────────────────────────

class AnalyzeProgress(Protocol):
    def advance_extract(self) -> None: ...
    def advance_cyclomatic(self) -> None: ...
    def advance_metrics(self, label: str) -> None: ...


class _LiveAnalyzeProgress:
    def __init__(self, progress, t1, t2, t3) -> None:
        self._progress = progress
        self._t1, self._t2, self._t3 = t1, t2, t3

    def advance_extract(self) -> None:
        self._progress.advance(self._t1)

    def advance_cyclomatic(self) -> None:
        self._progress.advance(self._t2)

    def advance_metrics(self, label: str) -> None:
        self._progress.advance(self._t3)
        self._progress.update(self._t3, description=f'[3/3] Graph metrics: {label:<22}')


class _RecordingAnalyzeProgress:
    def __init__(self, events: list[dict]) -> None:
        self._events = events

    def advance_extract(self) -> None:
        self._events.append({'type': 'analyze_extract'})

    def advance_cyclomatic(self) -> None:
        self._events.append({'type': 'analyze_cyclomatic'})

    def advance_metrics(self, label: str) -> None:
        self._events.append({'type': 'analyze_metrics', 'label': label})


# ── Reporter protocol ──────────────────────────────────────────────────────────

class Reporter(Protocol):
    def building(self) -> None: ...
    def status(self, msg: str): ...
    def diff_summary(self, diff: FileDiff) -> None: ...
    def parse_progress(self, total: int, label: str): ...
    def analyze_progress(self, n_procs: int): ...
    def indexed(self, row_count: int) -> None: ...
    def done(self, *, parsed: int, errors: int,
             rows: int | None = None, diff: FileDiff | None = None) -> None: ...


# ── LiveReporter ───────────────────────────────────────────────────────────────

class LiveReporter:
    def __init__(self, console=None) -> None:
        from rich.console import Console
        self._c = console or Console(stderr=True)

    def building(self) -> None:
        self._c.print('[bold]Building pb-runner...[/bold]', highlight=False)

    def status(self, msg: str):
        return self._c.status(f'[dim]{msg}[/dim]')

    def diff_summary(self, diff: FileDiff) -> None:
        parts = []
        if diff.new:
            parts.append(f'{len(diff.new)} new')
        if diff.changed:
            parts.append(f'{len(diff.changed)} changed')
        if diff.deleted:
            parts.append(f'{len(diff.deleted)} deleted')
        if diff.unchanged:
            parts.append(f'{len(diff.unchanged)} unchanged')
        if parts:
            self._c.print('[dim]' + ' · '.join(parts) + '[/dim]')

    @contextmanager
    def parse_progress(self, total: int, label: str) -> Iterator[_LiveParseProgress]:
        from rich.progress import (
            BarColumn, MofNCompleteColumn, Progress, TextColumn, TimeElapsedColumn,
        )
        with Progress(
            TextColumn('[bold blue]{task.description}[/bold blue]'),
            BarColumn(),
            MofNCompleteColumn(),
            TimeElapsedColumn(),
            TextColumn('{task.fields[err_str]}'),
            console=self._c,
        ) as progress:
            task = progress.add_task(label, total=total, err_str='')
            yield _LiveParseProgress(progress, task)

    @contextmanager
    def analyze_progress(self, n_procs: int) -> Iterator[_LiveAnalyzeProgress]:
        from rich.progress import (
            BarColumn, MofNCompleteColumn, Progress,
            SpinnerColumn, TextColumn, TimeElapsedColumn,
        )
        with Progress(
            SpinnerColumn(finished_text='[green]✓[/green]'),
            TextColumn('[bold]{task.description}'),
            BarColumn(),
            MofNCompleteColumn(),
            TimeElapsedColumn(),
            console=self._c,
        ) as progress:
            t1 = progress.add_task('[1/3] Extracting call graph      ', total=n_procs)
            t2 = progress.add_task('[2/3] Cyclomatic complexity       ', total=n_procs)
            t3 = progress.add_task('[3/3] Graph metrics: build graph  ', total=4)
            yield _LiveAnalyzeProgress(progress, t1, t2, t3)

    def indexed(self, row_count: int) -> None:
        self._c.print(f'[dim]Indexed {row_count:,} rows[/dim]')

    def done(self, *, parsed: int, errors: int,
             rows: int | None = None, diff: FileDiff | None = None) -> None:
        parts: list[str] = []
        if diff is not None:
            if diff.new:
                parts.append(f'{len(diff.new)} new')
            if diff.changed:
                parts.append(f'{len(diff.changed)} changed')
            if diff.deleted:
                parts.append(f'[dim]{len(diff.deleted)} deleted[/dim]')
            if not parts and diff.unchanged:
                parts.append(f'[dim]{len(diff.unchanged)} unchanged[/dim]')
        else:
            parts.append(f'{parsed} parsed')
        if rows is not None:
            parts.append(f'{rows:,} rows indexed')
        summary = ' · '.join(parts) if parts else 'no changes'
        if errors:
            self._c.print(f'[yellow]Done[/yellow] ({summary}) · [red]⚠ {errors} parse error(s)[/red]')
        else:
            self._c.print(f'[green]Done[/green] ({summary})')


# ── RecordingReporter (tests) ──────────────────────────────────────────────────

@dataclass
class RecordingReporter:
    """Test double: no rich dependency; all events are JSON-serialisable dicts."""
    events: list[dict] = field(default_factory=list)

    def building(self) -> None:
        self.events.append({'type': 'building'})

    @contextmanager
    def status(self, msg: str) -> Iterator[None]:
        self.events.append({'type': 'status', 'msg': msg})
        yield

    def diff_summary(self, diff: FileDiff) -> None:
        self.events.append({
            'type': 'diff_summary',
            'new': len(diff.new), 'changed': len(diff.changed),
            'deleted': len(diff.deleted), 'unchanged': len(diff.unchanged),
        })

    @contextmanager
    def parse_progress(self, total: int, label: str) -> Iterator[_RecordingParseProgress]:
        self.events.append({'type': 'parse_start', 'total': total, 'label': label})
        prog = _RecordingParseProgress(self.events)
        yield prog
        self.events.append({'type': 'parse_end', 'errors': prog.error_count})

    @contextmanager
    def analyze_progress(self, n_procs: int) -> Iterator[_RecordingAnalyzeProgress]:
        self.events.append({'type': 'analyze_start', 'n_procs': n_procs})
        prog = _RecordingAnalyzeProgress(self.events)
        yield prog
        self.events.append({'type': 'analyze_end'})

    def indexed(self, row_count: int) -> None:
        self.events.append({'type': 'indexed', 'row_count': row_count})

    def done(self, *, parsed: int, errors: int,
             rows: int | None = None, diff: FileDiff | None = None) -> None:
        self.events.append({
            'type': 'done', 'parsed': parsed, 'errors': errors, 'rows': rows,
            'diff': {
                'new': len(diff.new), 'changed': len(diff.changed), 'deleted': len(diff.deleted),
            } if diff is not None else None,
        })
