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

from contextlib import AbstractContextManager
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Callable, Iterable, Iterator, Protocol

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
from pb_cli.storage import (
    Conn,
    build_subset_tmpdir,
    compute_metrics,
    connect,
    create_schema,
    create_state_table,
    db_connection,
    delete_file_rows,
    diagram_calls,
    diagram_dw_tables,
    diagram_heatmap,
    diagram_inheritance,
    drop_tables,
    ingest_batch,
    load_file_state,
    run_from_jsonl_lines,
    save_file_state,
)

if TYPE_CHECKING:
    from pb_cli.reporter import AnalyzeProgress


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
        self,
        src_dir: Path,
        binary: Path,
        *,
        remap_from: Path | None = None,
        remap_to: Path | None = None,
    ) -> Iterator[tuple[bool, dict]]: ...


class RenderError(Protocol):
    def __call__(self, obj: dict) -> Panel: ...


class DbConnection(Protocol):
    def __call__(self, path: str | Path, read_only: bool = False) -> AbstractContextManager[Conn]: ...


class CreateSchema(Protocol):
    def __call__(self, conn: Conn) -> None: ...


class DropTables(Protocol):
    def __call__(self, conn: Conn) -> None: ...


class CreateStateTable(Protocol):
    def __call__(self, conn: Conn) -> None: ...


class LoadFileState(Protocol):
    def __call__(self, conn: Conn) -> dict[str, str]: ...


class DeleteFileRows(Protocol):
    def __call__(self, conn: Conn, file_path: str) -> None: ...


class SaveFileState(Protocol):
    def __call__(self, conn: Conn, file_states: dict[str, str]) -> None: ...


class BuildSubsetTmpdir(Protocol):
    def __call__(self, src_dir: Path, files: list[str]) -> Path: ...


class IngestBatch(Protocol):
    def __call__(
        self,
        objects: Iterable[dict],
        conn: Conn,
        dialect: str = "oracle",
        on_progress: Callable[[int], None] | None = None,
    ) -> int: ...


class RunFromJsonlLines(Protocol):
    def __call__(self, lines: Iterable[str], db: str = "pb.duckdb", dialect: str = "oracle") -> None: ...


class ComputeMetrics(Protocol):
    def __call__(self, conn: Conn, progress: AnalyzeProgress) -> None: ...


class Connect(Protocol):
    def __call__(self, db_path: str) -> AbstractContextManager[Conn]: ...


class DiagramInheritance(Protocol):
    def __call__(
        self,
        conn: Conn,
        root: str | None,
        output: str = "inheritance.svg",
        emit_dot: bool = False,
    ) -> None: ...


class DiagramCalls(Protocol):
    def __call__(
        self,
        conn: Conn,
        focal: str,
        depth: int = 2,
        output: str | None = None,
        emit_dot: bool = False,
    ) -> None: ...


class DiagramDwTables(Protocol):
    def __call__(
        self,
        conn: Conn,
        filter_table: str | None = None,
        output: str = "dw_tables.svg",
        emit_dot: bool = False,
    ) -> None: ...


class DiagramHeatmap(Protocol):
    def __call__(self, conn: Conn, output: str = "heatmap.svg", emit_dot: bool = False) -> None: ...


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
class StorageEnv:
    db_connection: DbConnection = field(default=db_connection)
    create_schema: CreateSchema = field(default=create_schema)
    drop_tables: DropTables = field(default=drop_tables)
    create_state_table: CreateStateTable = field(default=create_state_table)
    load_file_state: LoadFileState = field(default=load_file_state)
    delete_file_rows: DeleteFileRows = field(default=delete_file_rows)
    save_file_state: SaveFileState = field(default=save_file_state)
    build_subset_tmpdir: BuildSubsetTmpdir = field(default=build_subset_tmpdir)
    ingest_batch: IngestBatch = field(default=ingest_batch)
    run_from_jsonl_lines: RunFromJsonlLines = field(default=run_from_jsonl_lines)
    compute_metrics: ComputeMetrics = field(default=compute_metrics)
    connect: Connect = field(default=connect)
    diagram_inheritance: DiagramInheritance = field(default=diagram_inheritance)
    diagram_calls: DiagramCalls = field(default=diagram_calls)
    diagram_dw_tables: DiagramDwTables = field(default=diagram_dw_tables)
    diagram_heatmap: DiagramHeatmap = field(default=diagram_heatmap)


@dataclass
class ShellEnv:
    build: BuildEnv = field(default_factory=BuildEnv)
    runner: RunnerEnv = field(default_factory=RunnerEnv)
    storage: StorageEnv = field(default_factory=StorageEnv)


env = ShellEnv()
