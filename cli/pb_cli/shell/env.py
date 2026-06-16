"""Imperative-shell Environment: side-effecting boundary calls as data.

Every field is a closure with no captured side-effecting state of its own —
each one takes plain data in and returns plain data out, but reaches the
filesystem, a subprocess, or the network to do it. Bundling them on dataclasses
(rather than importing the underlying functions directly) means a caller can
swap any subset out for a test double by replacing fields on a copy of the
environment, without needing to patch module globals.

Structured hierarchically by domain (build vs. runner), composed into a single
top-level ShellEnv — the same pattern features/* uses for NavEnv/ObjectsEnv on
the TypeScript side.

Each callable field is typed with a Protocol (not `Callable[..., X]`) so that
default and keyword-only arguments on the real implementation are preserved
in the field's type — callers and test doubles are still checked against the
real signature, not an erased one.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator, Protocol

from rich.panel import Panel

from pb_cli.shell.build import (
    build_runner,
    count_sr_files,
    ensure_explorer_built,
    find_binary,
    find_repo,
    get_queries_dir,
    hash_source_dir,
    walk_sr_files,
)
from pb_cli.shell.runner import parse_stream, render_error


class FindRepo(Protocol):
    def __call__(self, repo: Path | None = None) -> Path: ...


class GetQueriesDir(Protocol):
    def __call__(self) -> Path: ...


class FindBinary(Protocol):
    def __call__(self, repo: Path) -> Path: ...


class BuildRunner(Protocol):
    def __call__(self, repo: Path, verbose: bool = False) -> Path: ...


class WalkSrFiles(Protocol):
    def __call__(self, src_dir: Path) -> list[Path]: ...


class CountSrFiles(Protocol):
    def __call__(self, src_dir: Path) -> int: ...


class HashSourceDir(Protocol):
    def __call__(self, src_dir: Path) -> dict[str, str]: ...


class EnsureExplorerBuilt(Protocol):
    def __call__(self, repo: Path, verbose: bool = False) -> None: ...


class ParseStream(Protocol):
    def __call__(
        self, src_dir: Path, binary: Path, *,
        remap_from: Path | None = None, remap_to: Path | None = None,
    ) -> Iterator[tuple[bool, dict]]: ...


class RenderError(Protocol):
    def __call__(self, obj: dict) -> Panel: ...


@dataclass
class BuildEnv:
    find_repo: FindRepo = field(default=find_repo)
    get_queries_dir: GetQueriesDir = field(default=get_queries_dir)
    find_binary: FindBinary = field(default=find_binary)
    build_runner: BuildRunner = field(default=build_runner)
    walk_sr_files: WalkSrFiles = field(default=walk_sr_files)
    count_sr_files: CountSrFiles = field(default=count_sr_files)
    hash_source_dir: HashSourceDir = field(default=hash_source_dir)
    ensure_explorer_built: EnsureExplorerBuilt = field(default=ensure_explorer_built)


@dataclass
class RunnerEnv:
    parse_stream: ParseStream = field(default=parse_stream)
    render_error: RenderError = field(default=render_error)


@dataclass
class ShellEnv:
    build: BuildEnv = field(default_factory=BuildEnv)
    runner: RunnerEnv = field(default_factory=RunnerEnv)


env = ShellEnv()
