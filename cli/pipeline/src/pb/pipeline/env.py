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

Fields whose real function has keyword-only parameters or defaults that call
sites rely on are typed with a Protocol preserving the full signature. All
others use plain ``Callable[[...], ...]`` annotations — pyright still checks
the assigned function against the field's type, but no class boilerplate is
needed where the real signature adds nothing a Callable cannot express.
"""

from __future__ import annotations

from contextlib import AbstractContextManager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Protocol

from pb.pipeline.build import (
    build_runner,
    count_sr_files,
    ensure_explorer_built,
    find_binary,
    find_repo,
    get_queries_dir,
    hash_pbl_dir,
    hash_source_dir,
    walk_sr_files,
)
from pb.pipeline.db import (
    Conn,
    count_sql_parse_failures,
    db_connection,
)
from pb.pipeline.reporter import LiveReporter, Reporter
from pb.pipeline.runner import render_error
from rich.panel import Panel


class FindRepo(Protocol):
    def __call__(self, repo: Path | None = None) -> Path: ...


class BuildRunner(Protocol):
    def __call__(self, repo: Path, verbose: bool = False) -> Path: ...


class EnsureExplorerBuilt(Protocol):
    def __call__(self, repo: Path, verbose: bool = False) -> None: ...


class DbConnection(Protocol):
    def __call__(self, path: str | Path, read_only: bool = False) -> AbstractContextManager[Conn]: ...


@dataclass
class BuildEnv:
    find_repo: FindRepo = field(default=find_repo)
    get_queries_dir: Callable[[], Path] = field(default=get_queries_dir)
    find_binary: Callable[[Path], Path] = field(default=find_binary)
    build_runner: BuildRunner = field(default=build_runner)
    walk_sr_files: Callable[[Path], list[Path]] = field(default=walk_sr_files)
    count_sr_files: Callable[[Path], int] = field(default=count_sr_files)
    hash_source_dir: Callable[[Path], dict[str, str]] = field(default=hash_source_dir)
    hash_pbl_dir: Callable[[Path], dict[str, str]] = field(default=hash_pbl_dir)
    ensure_explorer_built: EnsureExplorerBuilt = field(default=ensure_explorer_built)


@dataclass
class RunnerEnv:
    render_error: Callable[[dict], Panel] = field(default=render_error)


@dataclass
class StorageEnv:
    db_connection: DbConnection = field(default=db_connection)
    count_sql_parse_failures: Callable[[Conn], int] = field(default=count_sql_parse_failures)


@dataclass
class ShellEnv:
    build: BuildEnv = field(default_factory=BuildEnv)
    runner: RunnerEnv = field(default_factory=RunnerEnv)
    storage: StorageEnv = field(default_factory=StorageEnv)
    reporter: Reporter = field(default_factory=LiveReporter)


env = ShellEnv()
