"""pb — PowerBuilder codebase analysis tools."""

import shutil
import socket
import webbrowser
from contextlib import nullcontext
from pathlib import Path
from threading import Timer
from typing import Optional

import typer
import uvicorn
from pb.pipeline.commands.bombadil import app as bombadil_app
from pb.pipeline.commands.clean import ALL_TARGETS as CLEAN_TARGETS
from pb.pipeline.commands.clean import run as run_clean
from pb.pipeline.commands.corpus import run as run_corpus
from pb.pipeline.env import env
from pb.pipeline.impact import run_impact
from pb.pipeline.index_job import IndexJob
from pb.pipeline.metrics import compute_metrics
from pb.pipeline.pbl import extract_to_dir, resolve_source_dir
from pb.pipeline.pipeline import db_is_current
from pb.pipeline.pipeline import run as run_pipeline
from pb.pipeline.queries import register_queries

app = typer.Typer(
    name="pb",
    no_args_is_help=True,
    help="PowerBuilder codebase analysis tools.",
)

query_app = typer.Typer(
    name="query",
    no_args_is_help=True,
    help="Run canned SQL queries against pb.duckdb.",
)
app.add_typer(query_app, name="query")
register_queries(query_app)

app.add_typer(bombadil_app, name="dev")


# ── pb index ───────────────────────────────────────────────────────────────────


@app.command()
def index(
    input_path: Path = typer.Argument(..., help="Source directory or .pbl file."),
    db: str = typer.Option("pb.duckdb", "--db", help="DuckDB database path."),
    no_build: bool = typer.Option(False, "--no-build", help="Skip cabal build step."),
    reset: bool = typer.Option(False, "--reset", help="Drop all tables and do a full re-parse."),
    sql_dialect: str = typer.Option("oracle", "--sql-dialect", help="SQL dialect for sqlglot (oracle/tsql/sybase)."),
    repo: Optional[Path] = typer.Option(None, "--repo", help="Repo root (auto-detect if omitted)."),
    ddl: list[str] = typer.Option(
        [],
        "--ddl",
        help="DDL schema file, optionally schema-tagged as SCHEMA:path (repeatable, "
        "e.g. --ddl CLIMS:clims.sql --ddl CLIMS_COMMON:common.sql). Populates "
        "catalog_columns/catalog_fks so Sch-based analyses (column usage, FK graph, etc.) "
        "have real data.",
    ),
    default_namespace: Optional[str] = typer.Option(
        None,
        "--default-namespace",
        help="Corpus's default DB schema (e.g. CLIMS). An unqualified table reference "
        "resolves against this schema when the DDL catalog confirms it defines that "
        "table; otherwise it stays unresolved. Optional -- omit for single-schema corpora.",
    ),
    diagnostics_report: Optional[str] = typer.Option(
        None,
        "--diagnostics-report",
        help="Write a post-run diagnostics report (JSON + HTML) to this path "
        "(e.g. /tmp/diagnostics). Produces <path>.json and <path>.html.",
    ),
    profile: bool = typer.Option(
        False,
        "--profile",
        help="Enable GHC RTS GC profiling output (passes +RTS -sstderr -RTS to pbc).",
    ),
) -> None:
    """Parse → import → analyze, incremental by default (only changed files).

    INPUT may be a directory of .sr* source files, a single .pbl library file,
    or a directory containing .pbl files (extracted transparently).
    """
    reporter = env.reporter
    repo_path = env.build.find_repo(repo)
    binary = env.build.find_binary(repo_path) if no_build else _build(repo_path, reporter)
    with resolve_source_dir(Path(input_path), reporter) as src_dir:
        run_pipeline(
            src_dir, db, binary, reporter, reset=reset, dialect=sql_dialect,
            input_path=input_path, ddl=ddl, default_namespace=default_namespace,
            diagnostics_report_path=diagnostics_report, profile=profile,
        )


# ── pb extract ────────────────────────────────────────────────────────────────


@app.command()
def extract(
    input_dir: Path = typer.Argument(..., help="Directory containing .pbl library files."),
    output_dir: Path = typer.Option(..., "-o", "--output", help="Output root for extracted source files."),
    force: bool = typer.Option(False, "--force", help="Wipe output if non-empty."),
) -> None:
    """Extract .pbl library files to per-library source directories.

    Each foo.pbl produces an output/foo.pbl/ directory of .sr* source files.
    Run once as a setup step before 'pb index' or 'cabal test'.
    """
    src = Path(input_dir).resolve()
    out = Path(output_dir)

    pbls = sorted(p for p in src.iterdir() if p.is_file() and p.suffix.lower() == ".pbl")
    if not pbls:
        typer.echo(f"No .pbl files found in {src}", err=True)
        raise typer.Exit(1)

    _prepare_output(out, force)
    reporter = env.reporter

    total = 0
    with reporter.extracting_progress(len(pbls)) as prog:
        for pbl in pbls:
            sub = out / pbl.name
            sub.mkdir(parents=True, exist_ok=True)
            written = extract_to_dir(pbl, sub)
            total += len(written)
            prog.advance()

    typer.echo(f"Extracted {total} source files from {len(pbls)} libraries to {out}")


# ── pb dead-code ──────────────────────────────────────────────────────────────


@app.command("dead-code")
def dead_code(
    db: str = typer.Option("pb.duckdb", "--db", help="DuckDB database path."),
) -> None:
    """List non-public procedures never transitively reached from any entry point."""
    import duckdb as _duckdb
    from pb.api.services.analysis import get_dead_code

    try:
        conn = _duckdb.connect(db, read_only=True)
    except Exception as e:
        typer.echo(f"Cannot open {db}: {e}", err=True)
        raise typer.Exit(1)
    try:
        dead = get_dead_code(conn)
    finally:
        conn.close()
    if not dead:
        typer.echo("(no dead code found)")
        return
    cols = list(dead[0].keys())
    widths = [len(c) for c in cols]
    str_rows = [[str(r[c]) if r[c] is not None else "" for c in cols] for r in dead]
    for row in str_rows:
        for i, val in enumerate(row):
            widths[i] = max(widths[i], len(val))
    typer.echo("  ".join(c.ljust(w) for c, w in zip(cols, widths)))
    typer.echo("  ".join("-" * w for w in widths))
    for row in str_rows:
        typer.echo("  ".join(val.ljust(w) for val, w in zip(row, widths)))


# ── pb impact ─────────────────────────────────────────────────────────────────


@app.command()
def impact(
    table: str = typer.Argument(..., help="DB table name to analyse"),
    column: str | None = typer.Option(None, "--column", "-c", help="Narrow to a specific column"),
    db: str = typer.Option("pb.duckdb", "--db", help="DuckDB database path"),
) -> None:
    """Print all PB objects affected if a DB table (or column) changes."""
    run_impact(table=table, column=column, db=db)


# ── pb clean ───────────────────────────────────────────────────────────────────


@app.command()
def clean(
    only: Optional[str] = typer.Option(
        None,
        "--only",
        help=f"Comma-separated subset of {{{','.join(CLEAN_TARGETS)}}}. Default: all.",
    ),
    repo: Optional[Path] = typer.Option(None, "--repo", help="Repo root (auto-detect if omitted)."),
) -> None:
    """Remove build artifacts: cabal dist-newstyle, ui node_modules/built explorer
    assets, Python caches, and .venv (including cli/.venv, which 'pb' itself may
    be running from via 'uv run --project cli' — removed last, after everything
    else, since unlinking files a running process still has open is safe on POSIX
    but not guaranteed on Windows)."""
    targets = [t.strip() for t in only.split(",")] if only else None
    run_clean(repo=repo, targets=targets)


# ── pb check-corpus ──────────────────────────────────────────────────────────


@app.command("check-corpus")
def check_corpus(
    no_build: bool = typer.Option(False, "--no-build", help="Skip cabal build step."),
    repo: Optional[Path] = typer.Option(None, "--repo", help="Repo root (auto-detect if omitted)."),
) -> None:
    """Run pbc on both corpora and fail if any files contain parse errors."""
    run_corpus(repo=repo, no_build=no_build)


# ── pb analyze ────────────────────────────────────────────────────────────────


@app.command()
def analyze(
    db: str = typer.Argument("pb.duckdb", help="DuckDB database path."),
) -> None:
    """Compute call graph metrics and populate object_metrics in pb.duckdb."""
    reporter = env.reporter
    with env.storage.db_connection(db) as conn, reporter.analyze_progress() as progress:
        compute_metrics(conn, progress)


# ── pb explore ─────────────────────────────────────────────────────────────────


def _port_in_use(host: str, port: int) -> bool:
    """Check if a port is already in use."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex((host, port)) == 0


@app.command()
def explore(
    input_path: Optional[Path] = typer.Argument(None, help="Source directory or .pbl file. If given, index first."),
    db: str = typer.Option("pb.duckdb", "--db", help="DuckDB database path."),
    host: str = typer.Option("127.0.0.1", "--host", help="Bind host."),
    port: int = typer.Option(8000, "--port", help="Bind port."),
    open_browser: bool = typer.Option(True, "--open/--no-open", help="Open browser on start."),
    no_build: bool = typer.Option(False, "--no-build", help="Skip cabal build step."),
    reset: bool = typer.Option(False, "--reset", help="Drop all tables and do a full re-parse."),
    sql_dialect: str = typer.Option("oracle", "--sql-dialect", help="SQL dialect for sqlglot (oracle/tsql/sybase)."),
    repo: Optional[Path] = typer.Option(None, "--repo", help="Repo root (auto-detect if omitted)."),
    ddl: list[str] = typer.Option(
        [],
        "--ddl",
        help="DDL schema file, optionally schema-tagged as SCHEMA:path (repeatable, "
        "e.g. --ddl CLIMS:clims.sql --ddl CLIMS_COMMON:common.sql). Populates "
        "catalog_columns/catalog_fks so Sch-based analyses (column usage, FK graph, etc.) "
        "have real data.",
    ),
    default_namespace: Optional[str] = typer.Option(
        None,
        "--default-namespace",
        help="Corpus's default DB schema (e.g. CLIMS). An unqualified table reference "
        "resolves against this schema when the DDL catalog confirms it defines that "
        "table; otherwise it stays unresolved. Optional -- omit for single-schema corpora.",
    ),
    diagnostics_report: Optional[str] = typer.Option(
        None,
        "--diagnostics-report",
        help="Write a post-run diagnostics report (JSON + HTML) to this path "
        "(e.g. /tmp/diagnostics). Produces <path>.json and <path>.html.",
    ),
    profile: bool = typer.Option(
        False,
        "--profile",
        help="Enable GHC RTS GC profiling output (passes +RTS -sstderr -RTS to pbc).",
    ),
) -> None:
    """Start the interactive DuckDB explorer web UI.

    If INPUT is given, index the source tree first. Indexing runs in the
    background: the browser opens and the explorer is reachable immediately,
    with live progress served at `/` until the index run completes.
    """
    reporter = env.reporter

    need_index = input_path is not None and (reset or not db_is_current(input_path, db))
    if input_path is not None and not need_index:
        typer.echo("Database is up-to-date, skipping index.")

    url = f"http://{host}:{port}"

    if _port_in_use(host, port):
        if open_browser:
            typer.echo(f"Explorer already running at {url} — opening browser.")
            webbrowser.open(url)
        else:
            typer.echo(f"Explorer already running at {url}.")
        return

    repo = env.build.find_repo()
    env.build.ensure_explorer_built(repo)

    from pb.api import create_app

    app = create_app(db)

    binary: Path | None = None
    src_dir_cm = nullcontext(None)
    if need_index:
        assert input_path is not None
        repo_path = env.build.find_repo(repo)
        binary = env.build.find_binary(repo_path) if no_build else _build(repo_path, reporter)
        src_dir_cm = resolve_source_dir(Path(input_path), reporter)

    with src_dir_cm as src_dir:
        if need_index:
            assert src_dir is not None and binary is not None
            index_job = IndexJob(
                src_dir, db, binary, reset=reset, dialect=sql_dialect,
                input_path=input_path, ddl=ddl, default_namespace=default_namespace,
                diagnostics_report_path=diagnostics_report, profile=profile,
            )
            app.state.index_job = index_job
            index_job.start()
            typer.echo(f"Indexing in the background — progress at {url}")

        if open_browser:
            Timer(1.0, webbrowser.open, args=[url]).start()

        uvicorn.run(app, host=host, port=port, log_level="info")


# ── private helpers ────────────────────────────────────────────────────────────


def _build(repo_path: Path, reporter) -> Path:
    reporter.building()
    return env.build.build_runner(repo_path)


def _prepare_output(out: Path, force: bool) -> None:
    if out.exists():
        if force:
            shutil.rmtree(out)
        elif any(out.iterdir()):
            typer.echo(
                f"Output directory exists and is non-empty: {out}\n"
                "Remove it first, or pass --force to wipe and recreate it.",
                err=True,
            )
            raise typer.Exit(1)
    out.mkdir(parents=True, exist_ok=True)
