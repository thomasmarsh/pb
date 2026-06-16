"""Unified output protocol for pipeline operations.

Two implementations:
  LiveReporter        — rich-backed; for CLI use
  RecordingReporter   — accumulates JSON-serialisable events; for tests
"""
from __future__ import annotations

from collections.abc import Callable, Iterator
from contextlib import AbstractContextManager, contextmanager
from dataclasses import dataclass, field
from typing import Protocol

from pb_cli.state import FileDiff

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
        self._events.append({'type': 'extracting_advance'})


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
        from pb_cli.parse import render_error
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
    def advance_metrics(self, label: str) -> None: ...


class _LiveAnalyzeProgress:
    def __init__(self, progress, task) -> None:
        self._progress = progress
        self._task = task

    def advance_metrics(self, label: str) -> None:
        self._progress.advance(self._task)
        self._progress.update(self._task, description=f'[2/2] Graph metrics: {label:<22}')


class _RecordingAnalyzeProgress:
    def __init__(self, events: list[dict]) -> None:
        self._events = events

    def advance_metrics(self, label: str) -> None:
        self._events.append({'type': 'analyze_metrics', 'label': label})


# ── Reporter protocol ──────────────────────────────────────────────────────────

class Reporter(Protocol):
    def building(self) -> None: ...
    def status(self, msg: str) -> AbstractContextManager[None]: ...
    def extracting_progress(self, total: int) -> AbstractContextManager[ExtractProgress]: ...
    def parse_progress(self, total: int, label: str) -> AbstractContextManager[ParseProgress]: ...
    def indexing_step(self) -> AbstractContextManager[Callable[[int], None]]: ...
    def analyze_progress(self) -> AbstractContextManager[AnalyzeProgress]: ...
    def done(self, *, parsed: int, errors: int,
             rows: int | None = None, diff: FileDiff | None = None) -> None: ...


# ── LiveReporter ───────────────────────────────────────────────────────────────

class LiveReporter:
    def __init__(self, console=None) -> None:
        from rich.console import Console
        self._c = console or Console(stderr=True)

    def building(self) -> None:
        self._c.print('[bold]Building pb-runner...[/bold]', highlight=False)

    @contextmanager
    def status(self, msg: str) -> Iterator[None]:
        with self._c.status(f'[dim]{msg}[/dim]'):
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
            SpinnerColumn(finished_text='[green]✓[/green]'),
            TextColumn('[bold]{task.description}'),
            BarColumn(),
            MofNCompleteColumn(),
            TimeElapsedColumn(),
            console=self._c,
        ) as progress:
            task = progress.add_task('Extracting PBLs', total=total)
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
            SpinnerColumn(finished_text='[green]✓[/green]'),
            TextColumn('[bold]{task.description}[/bold]'),
            BarColumn(),
            MofNCompleteColumn(),
            TimeElapsedColumn(),
            TextColumn('{task.fields[err_str]}'),
            console=self._c,
        ) as progress:
            task = progress.add_task(label, total=total, err_str='')
            yield _LiveParseProgress(progress, task)

    @contextmanager
    def indexing_step(self) -> Iterator[Callable[[int], None]]:
        from rich.progress import Progress, SpinnerColumn, TextColumn, TimeElapsedColumn
        total_rows = 0
        with Progress(
            SpinnerColumn(finished_text='[green]✓[/green]'),
            TextColumn('[bold]{task.description}[/bold]'),
            TimeElapsedColumn(),
            console=self._c,
        ) as progress:
            task = progress.add_task('[1/2] Indexing', total=None)

            def advance(n: int) -> None:
                nonlocal total_rows
                total_rows += n
                progress.update(task, description=f'[1/2] Indexing  {total_rows:,} rows')

            yield advance
            progress.update(task, total=1, completed=1,
                            description=f'[1/2] Indexing  {total_rows:,} rows')

    @contextmanager
    def analyze_progress(self) -> Iterator[_LiveAnalyzeProgress]:
        from rich.progress import (
            Progress,
            SpinnerColumn,
            TextColumn,
            TimeElapsedColumn,
        )
        with Progress(
            SpinnerColumn(finished_text='[green]✓[/green]'),
            TextColumn('[bold]{task.description}'),
            TimeElapsedColumn(),
            console=self._c,
        ) as progress:
            task = progress.add_task('[2/2] Graph metrics: build graph  ', total=4)
            yield _LiveAnalyzeProgress(progress, task)


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

    @contextmanager
    def extracting_progress(self, total: int) -> Iterator[_RecordingExtractProgress]:
        self.events.append({'type': 'extracting_start', 'total': total})
        prog = _RecordingExtractProgress(self.events)
        yield prog
        self.events.append({'type': 'extracting_end'})

    @contextmanager
    def parse_progress(self, total: int, label: str) -> Iterator[_RecordingParseProgress]:
        self.events.append({'type': 'parse_start', 'total': total, 'label': label})
        prog = _RecordingParseProgress(self.events)
        yield prog
        self.events.append({'type': 'parse_end', 'errors': prog.error_count})

    @contextmanager
    def indexing_step(self) -> Iterator[Callable[[int], None]]:
        self.events.append({'type': 'indexing_start'})

        def advance(n: int) -> None:
            self.events.append({'type': 'index_chunk', 'n': n})

        yield advance
        self.events.append({'type': 'indexing_end'})

    @contextmanager
    def analyze_progress(self) -> Iterator[_RecordingAnalyzeProgress]:
        self.events.append({'type': 'analyze_start'})
        prog = _RecordingAnalyzeProgress(self.events)
        yield prog
        self.events.append({'type': 'analyze_end'})

    def done(self, *, parsed: int, errors: int,
             rows: int | None = None, diff: FileDiff | None = None) -> None:
        self.events.append({
            'type': 'done', 'parsed': parsed, 'errors': errors, 'rows': rows,
            'diff': {
                'new': len(diff.new), 'changed': len(diff.changed), 'deleted': len(diff.deleted),
            } if diff is not None else None,
        })
