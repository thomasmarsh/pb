"""pb — PowerBuilder codebase analysis tools."""
import shutil
import sys
from pathlib import Path
from typing import Optional

import typer

from pbtools.queries import register_queries

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
    input_path: Path = typer.Option(..., '-i', '--input',  help="Source directory or .pbl file."),
    output_dir: Path = typer.Option(..., '-o', '--output', help="Output JSON tree directory."),
    no_build: bool   = typer.Option(False, '--no-build',   help="Skip cabal build step."),
    force: bool      = typer.Option(False, '--force',      help="Wipe OUTDIR if it exists."),
    repo: Optional[Path] = typer.Option(None, '--repo',    help="Repo root (auto-detect if omitted)."),
) -> None:
    """Parse a PowerBuilder source tree to a mirrored JSON file tree.

    INPUT may be a directory of .sr* source files, a single .pbl library file,
    or a directory containing .pbl files (extracted transparently).
    """
    from pbtools.build import find_repo, find_binary
    from pbtools.dump import run as run_dump
    from pbtools.pbl import resolve_source_dir
    from pbtools.reporter import LiveReporter

    reporter = LiveReporter()
    repo_path = find_repo(repo)

    _prepare_output(Path(output_dir), force)
    binary = find_binary(repo_path) if no_build else _build(repo_path, reporter)
    with resolve_source_dir(Path(input_path), reporter) as src_dir:
        run_dump(src_dir, Path(output_dir), binary, reporter)


# ── pb run ─────────────────────────────────────────────────────────────────────

@app.command()
def run(
    input_path: Path = typer.Option(..., '-i', '--input', help="Source directory or .pbl file."),
    db: str          = typer.Option('pb.duckdb', '--db',  help="DuckDB database path."),
    no_build: bool   = typer.Option(False, '--no-build',  help="Skip cabal build step."),
    reset: bool      = typer.Option(False, '--reset',     help="Drop all tables and do a full re-parse."),
    repo: Optional[Path] = typer.Option(None, '--repo',   help="Repo root (auto-detect if omitted)."),
) -> None:
    """Parse → index → analyze, incremental by default (only changed files).

    INPUT may be a directory of .sr* source files, a single .pbl library file,
    or a directory containing .pbl files (extracted transparently).
    """
    from pbtools.build import find_repo, find_binary
    from pbtools.pipeline import run as run_pipeline
    from pbtools.pbl import resolve_source_dir
    from pbtools.reporter import LiveReporter

    reporter = LiveReporter()
    repo_path = find_repo(repo)
    binary = find_binary(repo_path) if no_build else _build(repo_path, reporter)
    with resolve_source_dir(Path(input_path), reporter) as src_dir:
        run_pipeline(src_dir, db, binary, reporter, reset=reset)


# ── pb extract ────────────────────────────────────────────────────────────────

@app.command()
def extract(
    input_dir: Path  = typer.Option(..., '-i', '--input',  help="Directory containing .pbl library files."),
    output_dir: Path = typer.Option(..., '-o', '--output', help="Output root for extracted source files."),
    force: bool      = typer.Option(False, '--force',      help="Wipe output if non-empty."),
) -> None:
    """Extract .pbl library files to per-library source directories.

    Each foo.pbl produces an output/foo.pbl/ directory of .sr* source files.
    Run once as a setup step before 'pb dump', 'pb run', or 'cabal test'.
    """
    from pbtools.pbl import extract_to_dir
    from pbtools.reporter import LiveReporter

    src = Path(input_dir).resolve()
    out = Path(output_dir)

    pbls = sorted(p for p in src.iterdir() if p.is_file() and p.suffix.lower() == '.pbl')
    if not pbls:
        typer.echo(f"No .pbl files found in {src}", err=True)
        raise typer.Exit(1)

    _prepare_output(out, force)
    reporter = LiveReporter()

    total = 0
    for pbl in pbls:
        reporter.extracting(pbl)
        sub = out / pbl.name
        sub.mkdir(parents=True, exist_ok=True)
        written = extract_to_dir(pbl, sub)
        total += len(written)

    typer.echo(f"Extracted {total} source files from {len(pbls)} libraries to {out}")


# ── pb debt ────────────────────────────────────────────────────────────────────

@app.command()
def debt(
    no_build: bool = typer.Option(False, "--no-build", help="Skip cabal build step."),
    repo: Optional[Path] = typer.Option(None, "--repo", help="Repo root (auto-detect if omitted)."),
) -> None:
    """Analyze BsRaw + ExRaw debt and DW control coverage across both corpora."""
    from pbtools.debt import run
    run(repo=repo, no_build=no_build)


# ── pb index (legacy) ─────────────────────────────────────────────────────────

@app.command()
def index(
    db: str = typer.Argument("pb.duckdb", help="DuckDB database path."),
) -> None:
    """Populate pb.duckdb from pb-runner JSONL output (reads stdin). Use 'pb run' instead."""
    from pbtools.index import run_from_jsonl_lines
    run_from_jsonl_lines(sys.stdin, db)


# ── pb analyze ────────────────────────────────────────────────────────────────

@app.command()
def analyze(
    db: str = typer.Argument("pb.duckdb", help="DuckDB database path."),
) -> None:
    """Compute call graph metrics and populate object_metrics in pb.duckdb."""
    from pbtools.analyze import run
    from pbtools.reporter import LiveReporter
    run(db, LiveReporter())


# ── pb diagram * ──────────────────────────────────────────────────────────────

@diagram_app.command("inheritance")
def diagram_inheritance(
    db: str = typer.Option("pb.duckdb", "--db", help="DuckDB database path."),
    root: Optional[str] = typer.Option(None, "--root", help="Show subtree rooted at NAME."),
    output: str = typer.Option("inheritance.svg", "-o", "--output", help="Output file."),
    dot: bool = typer.Option(False, "--dot", help="Emit raw DOT source instead of SVG."),
) -> None:
    """Inheritance hierarchy diagram."""
    from pbtools.diagram import connect, diagram_inheritance as _d
    with connect(db) as conn:
        _d(conn, root, output, dot)


@diagram_app.command("calls")
def diagram_calls(
    object_name: str = typer.Option(..., "--object", help="Focal object name."),
    db: str = typer.Option("pb.duckdb", "--db", help="DuckDB database path."),
    depth: int = typer.Option(2, "--depth", help="Ego-graph radius."),
    output: Optional[str] = typer.Option(None, "-o", "--output", help="Output file."),
    dot: bool = typer.Option(False, "--dot", help="Emit raw DOT source instead of SVG."),
) -> None:
    """Call ego-graph centred on a named object."""
    from pbtools.diagram import connect, diagram_calls as _d
    with connect(db) as conn:
        _d(conn, object_name, depth, output, dot)


@diagram_app.command("dw-tables")
def diagram_dw_tables(
    db: str = typer.Option("pb.duckdb", "--db", help="DuckDB database path."),
    table: Optional[str] = typer.Option(None, "--table", help="Filter to a single DB table."),
    output: str = typer.Option("dw_tables.svg", "-o", "--output", help="Output file."),
    dot: bool = typer.Option(False, "--dot", help="Emit raw DOT source instead of SVG."),
) -> None:
    """DataWindow → DB table bipartite dependency graph."""
    from pbtools.diagram import connect, diagram_dw_tables as _d
    with connect(db) as conn:
        _d(conn, table, output, dot)


@diagram_app.command("heatmap")
def diagram_heatmap(
    db: str = typer.Option("pb.duckdb", "--db", help="DuckDB database path."),
    output: str = typer.Option("heatmap.svg", "-o", "--output", help="Output file."),
    dot: bool = typer.Option(False, "--dot", help="Emit raw DOT source instead of SVG."),
) -> None:
    """Complexity heatmap over all PowerScript objects."""
    from pbtools.diagram import connect, diagram_heatmap as _d
    with connect(db) as conn:
        _d(conn, output, dot)


# ── private helpers ────────────────────────────────────────────────────────────

def _build(repo_path: Path, reporter) -> Path:
    from pbtools.build import build_runner
    reporter.building()
    return build_runner(repo_path)


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
