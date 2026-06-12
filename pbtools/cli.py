"""pb — PowerBuilder codebase analysis tools."""
import sys
from pathlib import Path
from typing import Optional

import typer

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
# pb index
# ---------------------------------------------------------------------------

@app.command()
def index(
    db: str = typer.Argument("pb.duckdb", help="DuckDB database path."),
) -> None:
    """Populate pb.duckdb from pb-runner JSONL output (reads stdin)."""
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
