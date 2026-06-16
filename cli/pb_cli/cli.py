"""pb — PowerBuilder codebase analysis tools."""

import shutil
import sys
from pathlib import Path
from typing import Optional

import typer

from pb_cli.queries import register_queries

app = typer.Typer(
    name="pb",
    no_args_is_help=True,
    help="PowerBuilder codebase analysis tools.",
)

diagram_app = typer.Typer(
    name="diagram",
    no_args_is_help=True,
    help="Generate SVG diagrams from pb.duckdb.",
)
app.add_typer(diagram_app, name="diagram")

query_app = typer.Typer(
    name="query",
    no_args_is_help=True,
    help="Run canned SQL queries against pb.duckdb.",
)
app.add_typer(query_app, name="query")
register_queries(query_app)


# ── pb dump ────────────────────────────────────────────────────────────────────


@app.command()
def dump(
    input_path: Path = typer.Argument(..., help="Source directory or .pbl file."),
    output_dir: Path = typer.Option(..., "-o", "--output", help="Output JSON tree directory."),
    no_build: bool = typer.Option(False, "--no-build", help="Skip cabal build step."),
    force: bool = typer.Option(False, "--force", help="Wipe OUTDIR if it exists."),
    repo: Optional[Path] = typer.Option(None, "--repo", help="Repo root (auto-detect if omitted)."),
) -> None:
    """Parse a PowerBuilder source tree to a mirrored JSON file tree.

    INPUT may be a directory of .sr* source files, a single .pbl library file,
    or a directory containing .pbl files (extracted transparently).
    """
    from pb_cli.dump import run as run_dump
    from pb_cli.pbl import resolve_source_dir
    from pb_cli.shell.env import env

    reporter = env.reporter
    repo_path = env.build.find_repo(repo)

    _prepare_output(Path(output_dir), force)
    binary = env.build.find_binary(repo_path) if no_build else _build(repo_path, reporter)
    with resolve_source_dir(Path(input_path), reporter) as src_dir:
        run_dump(src_dir, Path(output_dir), binary, reporter)


# ── pb ingest ──────────────────────────────────────────────────────────────────


@app.command()
def ingest(
    input_path: Path = typer.Argument(..., help="Source directory or .pbl file."),
    db: str = typer.Option("pb.duckdb", "--db", help="DuckDB database path."),
    no_build: bool = typer.Option(False, "--no-build", help="Skip cabal build step."),
    reset: bool = typer.Option(False, "--reset", help="Drop all tables and do a full re-parse."),
    sql_dialect: str = typer.Option("oracle", "--sql-dialect", help="SQL dialect for sqlglot (oracle/tsql/sybase)."),
    repo: Optional[Path] = typer.Option(None, "--repo", help="Repo root (auto-detect if omitted)."),
) -> None:
    """Parse → index → analyze, incremental by default (only changed files).

    INPUT may be a directory of .sr* source files, a single .pbl library file,
    or a directory containing .pbl files (extracted transparently).
    """
    from pb_cli.pbl import resolve_source_dir
    from pb_cli.shell.env import env
    from pb_cli.shell.pipeline import run as run_pipeline

    reporter = env.reporter
    repo_path = env.build.find_repo(repo)
    binary = env.build.find_binary(repo_path) if no_build else _build(repo_path, reporter)
    with resolve_source_dir(Path(input_path), reporter) as src_dir:
        run_pipeline(src_dir, db, binary, reporter, reset=reset, dialect=sql_dialect)


# ── pb extract ────────────────────────────────────────────────────────────────


@app.command()
def extract(
    input_dir: Path = typer.Argument(..., help="Directory containing .pbl library files."),
    output_dir: Path = typer.Option(..., "-o", "--output", help="Output root for extracted source files."),
    force: bool = typer.Option(False, "--force", help="Wipe output if non-empty."),
) -> None:
    """Extract .pbl library files to per-library source directories.

    Each foo.pbl produces an output/foo.pbl/ directory of .sr* source files.
    Run once as a setup step before 'pb dump', 'pb ingest', or 'cabal test'.
    """
    from pb_cli.pbl import extract_to_dir
    from pb_cli.shell.env import env

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


# ── pb debt ────────────────────────────────────────────────────────────────────


@app.command()
def debt(
    no_build: bool = typer.Option(False, "--no-build", help="Skip cabal build step."),
    repo: Optional[Path] = typer.Option(None, "--repo", help="Repo root (auto-detect if omitted)."),
) -> None:
    """Analyze BsRaw + ExRaw debt and DW control coverage across both corpora."""
    from pb_cli.debt import run

    run(repo=repo, no_build=no_build)


# ── pb check-corpus ──────────────────────────────────────────────────────────


@app.command("check-corpus")
def check_corpus(
    no_build: bool = typer.Option(False, "--no-build", help="Skip cabal build step."),
    repo: Optional[Path] = typer.Option(None, "--repo", help="Repo root (auto-detect if omitted)."),
) -> None:
    """Run pb-runner on both corpora and fail if any files contain parse errors."""
    from pb_cli.corpus import run

    run(repo=repo, no_build=no_build)


# ── pb index (legacy) ─────────────────────────────────────────────────────────


@app.command()
def index(
    db: str = typer.Argument("pb.duckdb", help="DuckDB database path."),
) -> None:
    """Populate pb.duckdb from pb-runner JSONL output (reads stdin). Use 'pb ingest' instead."""
    from pb_cli.shell.env import env

    env.storage.run_from_jsonl_lines(sys.stdin, db)


# ── pb analyze ────────────────────────────────────────────────────────────────


@app.command()
def analyze(
    db: str = typer.Argument("pb.duckdb", help="DuckDB database path."),
) -> None:
    """Compute call graph metrics and populate object_metrics in pb.duckdb."""
    from pb_cli.shell.env import env

    reporter = env.reporter
    with env.storage.db_connection(db) as conn, reporter.analyze_progress() as progress:
        env.storage.compute_metrics(conn, progress)


# ── pb diagram * ──────────────────────────────────────────────────────────────


@diagram_app.command("inheritance")
def diagram_inheritance(
    db: str = typer.Option("pb.duckdb", "--db", help="DuckDB database path."),
    root: Optional[str] = typer.Option(None, "--root", help="Show subtree rooted at NAME."),
    output: str = typer.Option("inheritance.svg", "-o", "--output", help="Output file."),
    dot: bool = typer.Option(False, "--dot", help="Emit raw DOT source instead of SVG."),
) -> None:
    """Inheritance hierarchy diagram."""
    from pb_cli.shell.env import env

    with env.storage.connect(db) as conn:
        env.storage.diagram_inheritance(conn, root, output, dot)


@diagram_app.command("calls")
def diagram_calls(
    object_name: str = typer.Option(..., "--object", help="Focal object name."),
    db: str = typer.Option("pb.duckdb", "--db", help="DuckDB database path."),
    depth: int = typer.Option(2, "--depth", help="Ego-graph radius."),
    output: Optional[str] = typer.Option(None, "-o", "--output", help="Output file."),
    dot: bool = typer.Option(False, "--dot", help="Emit raw DOT source instead of SVG."),
) -> None:
    """Call ego-graph centred on a named object."""
    from pb_cli.shell.env import env

    with env.storage.connect(db) as conn:
        env.storage.diagram_calls(conn, object_name, depth, output, dot)


@diagram_app.command("dw-tables")
def diagram_dw_tables(
    db: str = typer.Option("pb.duckdb", "--db", help="DuckDB database path."),
    table: Optional[str] = typer.Option(None, "--table", help="Filter to a single DB table."),
    output: str = typer.Option("dw_tables.svg", "-o", "--output", help="Output file."),
    dot: bool = typer.Option(False, "--dot", help="Emit raw DOT source instead of SVG."),
) -> None:
    """DataWindow → DB table bipartite dependency graph."""
    from pb_cli.shell.env import env

    with env.storage.connect(db) as conn:
        env.storage.diagram_dw_tables(conn, table, output, dot)


@diagram_app.command("heatmap")
def diagram_heatmap(
    db: str = typer.Option("pb.duckdb", "--db", help="DuckDB database path."),
    output: str = typer.Option("heatmap.svg", "-o", "--output", help="Output file."),
    dot: bool = typer.Option(False, "--dot", help="Emit raw DOT source instead of SVG."),
) -> None:
    """Complexity heatmap over all PowerScript objects."""
    from pb_cli.shell.env import env

    with env.storage.connect(db) as conn:
        env.storage.diagram_heatmap(conn, output, dot)


# ── pb explore ─────────────────────────────────────────────────────────────────


def _port_in_use(host: str, port: int) -> bool:
    """Check if a port is already in use."""
    import socket

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex((host, port)) == 0


@app.command()
def explore(
    db: str = typer.Option("pb.duckdb", "--db", help="DuckDB database path."),
    host: str = typer.Option("127.0.0.1", "--host", help="Bind host."),
    port: int = typer.Option(8000, "--port", help="Bind port."),
    open_browser: bool = typer.Option(True, "--open/--no-open", help="Open browser on start."),
) -> None:
    """Start the interactive DuckDB explorer web UI."""
    import uvicorn

    from pb_cli.explorer import create_app
    from pb_cli.shell.env import env

    url = f"http://{host}:{port}"

    # If port is already in use, assume server is running — just open browser
    if _port_in_use(host, port):
        if open_browser:
            import webbrowser

            typer.echo(f"Explorer already running at {url} — opening browser.")
            webbrowser.open(url)
        else:
            typer.echo(f"Explorer already running at {url}.")
        return

    repo = env.build.find_repo()
    env.build.ensure_explorer_built(repo)

    app = create_app(db)

    if open_browser:
        import webbrowser
        from threading import Timer

        Timer(1.0, webbrowser.open, args=[url]).start()

    uvicorn.run(app, host=host, port=port, log_level="info")


# ── private helpers ────────────────────────────────────────────────────────────


def _build(repo_path: Path, reporter) -> Path:
    from pb_cli.shell.env import env

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
