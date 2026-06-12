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
register_queries(app)


# ---------------------------------------------------------------------------
# pb dump
# ---------------------------------------------------------------------------

@app.command()
def dump(
    input_dir: Path  = typer.Option(..., '-i', '--input',  help="Source root directory."),
    output_dir: Path = typer.Option(..., '-o', '--output', help="Output JSON tree directory."),
    no_build: bool   = typer.Option(False, '--no-build',   help="Skip cabal build step."),
    force: bool      = typer.Option(False, '--force',      help="Wipe OUTDIR if it exists."),
    repo: Optional[Path] = typer.Option(None, '--repo',    help="Repo root (auto-detect if omitted)."),
) -> None:
    """Parse a PowerBuilder source tree to a mirrored JSON file tree."""
    import json as _json
    from rich.console import Console
    from rich.progress import BarColumn, MofNCompleteColumn, Progress, TextColumn, TimeElapsedColumn
    from pbtools.build import find_repo, build_runner, find_binary, count_sr_files
    from pbtools.parse import parse_stream, render_error

    console = Console(stderr=True)
    repo_path = find_repo(repo)
    src_dir = Path(input_dir).resolve()

    # Pre-existing output dir check
    out = Path(output_dir)
    if out.exists():
        if not force:
            has_content = any(True for _ in out.iterdir())
            if has_content:
                console.print(
                    f"[red]Output directory already exists and is non-empty:[/red] {out}\n"
                    "Remove it first, or use [bold]--force[/bold] to wipe and recreate it."
                )
                raise typer.Exit(1)
        else:
            shutil.rmtree(out)
    out.mkdir(parents=True, exist_ok=True)

    if not no_build:
        console.print('[bold]Building pb-runner...[/bold]', highlight=False)
        binary = build_runner(repo_path)
    else:
        binary = find_binary(repo_path)

    total = count_sr_files(src_dir)
    error_count = 0

    with Progress(
        TextColumn('[bold blue]{task.description}[/bold blue]'),
        BarColumn(),
        MofNCompleteColumn(),
        TimeElapsedColumn(),
        TextColumn('{task.fields[err_str]}'),
        console=console,
    ) as progress:
        task = progress.add_task('Parsing ', total=total, err_str='')
        for is_err, obj in parse_stream(src_dir, binary):
            if is_err:
                error_count += 1
                progress.update(task, err_str=f'[red]⚠ {error_count} errors[/red]')
                progress.console.print(render_error(obj))
            else:
                src_file = obj.get('file', '')
                try:
                    rel = Path(src_file).relative_to(src_dir)
                except ValueError:
                    rel = Path(Path(src_file).name)
                out_path = out / (str(rel) + '.json')
                out_path.parent.mkdir(parents=True, exist_ok=True)
                out_path.write_text(_json.dumps(obj))
            progress.advance(task)

    if error_count:
        console.print(f'[red]⚠ {error_count} file(s) failed to parse.[/red]')
    else:
        console.print(f'[green]Done.[/green] {total} files parsed.')


# ---------------------------------------------------------------------------
# pb run  (parse → index → analyze, incremental)
# ---------------------------------------------------------------------------

@app.command()
def run(
    input_dir: Path = typer.Option(..., '-i', '--input', help="Source root directory."),
    db: str         = typer.Option('pb.duckdb', '--db',  help="DuckDB database path."),
    no_build: bool  = typer.Option(False, '--no-build',  help="Skip cabal build step."),
    reset: bool     = typer.Option(False, '--reset',     help="Drop all tables and do a full re-parse."),
    repo: Optional[Path] = typer.Option(None, '--repo',  help="Repo root (auto-detect if omitted)."),
) -> None:
    """Parse → index → analyze, incremental by default (only changed files)."""
    import duckdb
    from rich.console import Console
    from rich.progress import BarColumn, MofNCompleteColumn, Progress, TextColumn, TimeElapsedColumn
    from pbtools.build import find_repo, build_runner, find_binary
    from pbtools.parse import parse_stream, render_error
    from pbtools.common import create_schema, drop_tables
    from pbtools.state import (
        hash_source_dir, load_file_state, diff_state,
        delete_file_rows, save_file_state,
        build_subset_tmpdir, create_state_table,
    )
    from pbtools.index import ingest_batch
    from pbtools.analyze import run as run_analyze

    console = Console(stderr=True)
    repo_path = find_repo(repo)
    src_dir = Path(input_dir).resolve()

    if not no_build:
        console.print('[bold]Building pb-runner...[/bold]', highlight=False)
        binary = build_runner(repo_path)
    else:
        binary = find_binary(repo_path)

    conn = duckdb.connect(db)
    if reset:
        drop_tables(conn)
    create_schema(conn)
    create_state_table(conn)

    # --- Incremental diff ---
    with console.status('[dim]Scanning source files...[/dim]'):
        current = hash_source_dir(src_dir)
    stored = load_file_state(conn)
    diff = diff_state(current, stored)

    if not diff.new and not diff.changed and not diff.deleted:
        console.print(
            f'[green]Nothing to do[/green] — {len(diff.unchanged)} file(s) unchanged.'
        )
        conn.close()
        return

    # Summarise what's changing
    parts = []
    if diff.new:       parts.append(f'{len(diff.new)} new')
    if diff.changed:   parts.append(f'{len(diff.changed)} changed')
    if diff.deleted:   parts.append(f'{len(diff.deleted)} deleted')
    if diff.unchanged: parts.append(f'{len(diff.unchanged)} unchanged')
    console.print('[dim]' + ' · '.join(parts) + '[/dim]')

    # Remove stale rows for deleted and changed files
    for f in diff.deleted + diff.changed:
        delete_file_rows(conn, f)
    if diff.deleted:
        console.print(f'[dim]Removed {len(diff.deleted)} deleted file(s) from database.[/dim]')

    to_parse = diff.new + diff.changed
    if not to_parse:
        # Only deletions — skip parse, go straight to analyze
        conn.close()
        console.print('[bold]Analyzing...[/bold]')
        run_analyze(db, console=console)
        _print_summary(console, diff, 0)
        return

    # Parse the subset via a tmpdir (hard-link or copy, then remap paths back)
    tmpdir = build_subset_tmpdir(src_dir, to_parse)
    try:
        error_count = 0
        objects: list[dict] = []

        with Progress(
            TextColumn('[bold blue]{task.description}[/bold blue]'),
            BarColumn(),
            MofNCompleteColumn(),
            TimeElapsedColumn(),
            TextColumn('{task.fields[err_str]}'),
            console=console,
        ) as progress:
            task = progress.add_task('Parsing  ', total=len(to_parse), err_str='')
            for is_err, obj in parse_stream(tmpdir, binary,
                                            remap_from=tmpdir, remap_to=src_dir):
                if is_err:
                    error_count += 1
                    progress.update(task, err_str=f'[red]⚠ {error_count} errors[/red]')
                    progress.console.print(render_error(obj))
                else:
                    objects.append(obj)
                progress.advance(task)
    finally:
        shutil.rmtree(tmpdir)

    # Ingest
    with console.status('[dim]Indexing...[/dim]'):
        row_count = ingest_batch(objects, conn)
    console.print(f'[dim]Indexed {row_count:,} rows[/dim]')

    # Persist state only for successfully parsed files
    parsed_files = {obj['file'] for obj in objects}
    new_states = {f: current[f] for f in to_parse if f in parsed_files}
    save_file_state(conn, new_states)
    conn.close()

    # Analyze
    console.print('[bold]Analyzing...[/bold]')
    run_analyze(db, console=console)

    _print_summary(console, diff, error_count)


def _print_summary(console, diff, errors: int) -> None:
    parts = []
    if diff.new:     parts.append(f'{len(diff.new)} new')
    if diff.changed: parts.append(f'{len(diff.changed)} changed')
    if diff.deleted: parts.append(f'[dim]{len(diff.deleted)} deleted[/dim]')
    change_str = ' · '.join(parts) if parts else 'no content changes'
    if errors:
        console.print(
            f'\n[yellow]pb.duckdb updated[/yellow] ({change_str})'
            f' · [red]⚠ {errors} parse error(s)[/red]'
        )
    else:
        console.print(f'\n[green]pb.duckdb ready[/green] ({change_str})')


# ---------------------------------------------------------------------------
# pb debt
# ---------------------------------------------------------------------------

@app.command()
def debt(
    no_build: bool = typer.Option(False, "--no-build", help="Skip cabal build step."),
    repo: Optional[Path] = typer.Option(
        None, "--repo", help="Repo root (default: auto-detect via pb-ast.cabal)."
    ),
) -> None:
    """Analyze BsRaw + ExRaw debt and DW control coverage across both corpora."""
    from pbtools.debt import run
    run(repo=repo, no_build=no_build)


# ---------------------------------------------------------------------------
# pb index  (legacy: reads JSONL from stdin)
# ---------------------------------------------------------------------------

@app.command()
def index(
    db: str = typer.Argument("pb.duckdb", help="DuckDB database path."),
) -> None:
    """Populate pb.duckdb from pb-runner JSONL output (reads stdin). Use 'pb run' instead."""
    from pbtools.index import run_from_jsonl_lines
    run_from_jsonl_lines(sys.stdin, db)


# ---------------------------------------------------------------------------
# pb analyze
# ---------------------------------------------------------------------------

@app.command()
def analyze(
    db: str = typer.Argument("pb.duckdb", help="DuckDB database path."),
) -> None:
    """Compute call graph metrics and populate object_metrics in pb.duckdb."""
    from pbtools.analyze import run
    run(db)


# ---------------------------------------------------------------------------
# pb diagram inheritance
# ---------------------------------------------------------------------------

@diagram_app.command("inheritance")
def diagram_inheritance(
    db: str = typer.Option("pb.duckdb", "--db", help="DuckDB database path."),
    root: Optional[str] = typer.Option(None, "--root", help="Show subtree rooted at NAME."),
    output: str = typer.Option("inheritance.svg", "-o", "--output", help="Output file."),
    dot: bool = typer.Option(False, "--dot", help="Emit raw DOT source instead of SVG."),
) -> None:
    """Inheritance hierarchy diagram."""
    from pbtools.diagram import open_db, diagram_inheritance as _diagram
    conn = open_db(db)
    _diagram(conn, root, output, dot)
    conn.close()


# ---------------------------------------------------------------------------
# pb diagram calls
# ---------------------------------------------------------------------------

@diagram_app.command("calls")
def diagram_calls(
    object_name: str = typer.Option(..., "--object", help="Focal object name."),
    db: str = typer.Option("pb.duckdb", "--db", help="DuckDB database path."),
    depth: int = typer.Option(2, "--depth", help="Ego-graph radius."),
    output: Optional[str] = typer.Option(None, "-o", "--output", help="Output file."),
    dot: bool = typer.Option(False, "--dot", help="Emit raw DOT source instead of SVG."),
) -> None:
    """Call ego-graph centred on a named object."""
    from pbtools.diagram import open_db, diagram_calls as _diagram
    conn = open_db(db)
    _diagram(conn, object_name, depth, output, dot)
    conn.close()


# ---------------------------------------------------------------------------
# pb diagram dw-tables
# ---------------------------------------------------------------------------

@diagram_app.command("dw-tables")
def diagram_dw_tables(
    db: str = typer.Option("pb.duckdb", "--db", help="DuckDB database path."),
    table: Optional[str] = typer.Option(None, "--table", help="Filter to a single DB table."),
    output: str = typer.Option("dw_tables.svg", "-o", "--output", help="Output file."),
    dot: bool = typer.Option(False, "--dot", help="Emit raw DOT source instead of SVG."),
) -> None:
    """DataWindow → DB table bipartite dependency graph."""
    from pbtools.diagram import open_db, diagram_dw_tables as _diagram
    conn = open_db(db)
    _diagram(conn, table, output, dot)
    conn.close()


# ---------------------------------------------------------------------------
# pb diagram heatmap
# ---------------------------------------------------------------------------

@diagram_app.command("heatmap")
def diagram_heatmap(
    db: str = typer.Option("pb.duckdb", "--db", help="DuckDB database path."),
    output: str = typer.Option("heatmap.svg", "-o", "--output", help="Output file."),
    dot: bool = typer.Option(False, "--dot", help="Emit raw DOT source instead of SVG."),
) -> None:
    """Complexity heatmap over all PowerScript objects."""
    from pbtools.diagram import open_db, diagram_heatmap as _diagram
    conn = open_db(db)
    _diagram(conn, output, dot)
    conn.close()
