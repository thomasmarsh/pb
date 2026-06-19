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
from typing import TYPE_CHECKING, Callable, Iterable, Iterator, Protocol

from rich.panel import Panel

from pb_cli.core.models import ParseErrorRow
from pb_cli.shell.build import (
    build_runner,
    build_subset_tmpdir,
    count_sr_files,
    ensure_explorer_built,
    find_binary,
    find_repo,
    get_queries_dir,
    hash_pbl_dir,
    hash_source_dir,
    walk_sr_files,
)
from pb_cli.shell.db import (
    Conn,
    connect,
    count_sql_parse_failures,
    create_schema,
    db_connection,
    drop_tables,
    insert_parse_errors,
)
from pb_cli.shell.importing import import_batch, run_from_jsonl_lines
from pb_cli.shell.metrics import compute_dit, compute_metrics
from pb_cli.shell.reporter import LiveReporter, Reporter
from pb_cli.shell.runner import parse_stream, render_error
from pb_cli.shell.state import (
    create_state_table,
    delete_file_rows,
    load_file_state,
    save_file_state,
)
from pb_cli.shell.dataflow import build_dataflow_tables
from pb_cli.shell.interproc import build_interproc_tables
from pb_cli.shell.taint import build_taint_tables
from pb_cli.shell.type_resolution import build_type_tables

if TYPE_CHECKING:
    from pb_cli.shell.reporter import AnalyzeProgress


ConnOp = Callable[[Conn], None]


class FindRepo(Protocol):
    def __call__(self, repo: Path | None = None) -> Path: ...


class BuildRunner(Protocol):
    def __call__(self, repo: Path, verbose: bool = False) -> Path: ...


class EnsureExplorerBuilt(Protocol):
    def __call__(self, repo: Path, verbose: bool = False) -> None: ...


class ParseStream(Protocol):
    def __call__(
        self,
        src_dir: Path,
        binary: Path,
        *,
        remap_from: Path | None = None,
        remap_to: Path | None = None,
    ) -> Iterator[tuple[bool, dict]]: ...


class DbConnection(Protocol):
    def __call__(self, path: str | Path, read_only: bool = False) -> AbstractContextManager[Conn]: ...


class ImportBatch(Protocol):
    def __call__(
        self,
        objects: Iterable[dict],
        conn: Conn,
        dialect: str = "oracle",
        on_progress: Callable[[int], None] | None = None,
    ) -> int: ...


class RunFromJsonlLines(Protocol):
    def __call__(self, lines: Iterable[str], db: str = "pb.duckdb", dialect: str = "oracle") -> None: ...


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
    parse_stream: ParseStream = field(default=parse_stream)
    render_error: Callable[[dict], Panel] = field(default=render_error)


@dataclass
class StorageEnv:
    db_connection: DbConnection = field(default=db_connection)
    create_schema: ConnOp = field(default=create_schema)
    drop_tables: ConnOp = field(default=drop_tables)
    create_state_table: ConnOp = field(default=create_state_table)
    load_file_state: Callable[[Conn], dict[str, str]] = field(default=load_file_state)
    delete_file_rows: Callable[[Conn, str], None] = field(default=delete_file_rows)
    save_file_state: Callable[[Conn, dict[str, str]], None] = field(default=save_file_state)
    build_subset_tmpdir: Callable[[Path, list[str]], Path] = field(default=build_subset_tmpdir)
    import_batch: ImportBatch = field(default=import_batch)
    run_from_jsonl_lines: RunFromJsonlLines = field(default=run_from_jsonl_lines)
    compute_dit: Callable[[Conn], dict[str, int]] = field(default=compute_dit)
    count_sql_parse_failures: Callable[[Conn], int] = field(default=count_sql_parse_failures)
    insert_parse_errors: Callable[[Conn, list[ParseErrorRow]], None] = field(default=insert_parse_errors)
    compute_metrics: Callable[[Conn, AnalyzeProgress], None] = field(default=compute_metrics)
    build_type_tables: Callable[[Conn], None] = field(default=build_type_tables)
    build_dataflow_tables: Callable[[Conn], None] = field(default=build_dataflow_tables)
    build_interproc_tables: Callable[[Conn], None] = field(default=build_interproc_tables)
    build_taint_tables: Callable[[Conn], None] = field(default=build_taint_tables)
    connect: Callable[[str], AbstractContextManager[Conn]] = field(default=connect)


@dataclass
class ShellEnv:
    build: BuildEnv = field(default_factory=BuildEnv)
    runner: RunnerEnv = field(default_factory=RunnerEnv)
    storage: StorageEnv = field(default_factory=StorageEnv)
    reporter: Reporter = field(default_factory=LiveReporter)


env = ShellEnv()
