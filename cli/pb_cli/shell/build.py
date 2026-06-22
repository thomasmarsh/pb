"""Build management: find repo root, build pb-runner, enumerate source files."""

import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def find_repo(repo: Path | None = None) -> Path:
    if repo:
        return repo
    for p in [Path.cwd(), *Path.cwd().parents]:
        if (p / "parser" / "pb-ast.cabal").exists():
            return p
    sys.exit(
        "error: cannot locate repo root (no parser/pb-ast.cabal found). Run from within the pb repo, or pass --repo."
    )


def get_queries_dir() -> Path:
    """Lazy accessor for the queries/ directory — avoids import-time find_repo()."""
    return find_repo() / "queries"


def find_binary(repo: Path) -> Path:
    """Return the compiled pb-runner binary path without triggering a build."""
    r = subprocess.run(
        ["cabal", "list-bin", "pb-runner"],
        cwd=str(repo / "parser"),
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        sys.exit("error: cabal list-bin pb-runner failed — try without --no-build")
    binary = Path(r.stdout.strip())
    if not binary.exists():
        sys.exit(f"error: binary not found at {binary} — try without --no-build")
    return binary


def build_runner(repo: Path, verbose: bool = False) -> Path:
    """Build pb-runner via cabal and return the compiled binary path."""
    verbosity = [] if verbose else ["-v0"]
    r = subprocess.run(
        ["cabal", "build", "pb-runner"] + verbosity,
        cwd=str(repo / "parser"),
        capture_output=not verbose,
        text=True,
    )
    if r.returncode != 0:
        if not verbose:
            print(r.stderr, file=sys.stderr)
        sys.exit(1)
    return find_binary(repo)


_SR_EXT = re.compile(r"\.sr[a-z]$", re.IGNORECASE)


def walk_sr_files(src_dir: Path) -> list[Path]:
    """Return all .sr<x> source files under src_dir as absolute Paths."""
    root = Path(src_dir).resolve()
    return [f for f in root.rglob("*") if f.is_file() and _SR_EXT.search(f.name)]


def count_sr_files(src_dir: Path) -> int:
    return len(walk_sr_files(src_dir))


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hash_source_dir(src_dir: Path) -> dict[str, str]:
    """SHA256-hash every .sr* file under src_dir. Keys are relative path strings."""
    root = Path(src_dir).resolve()
    return {str(f.relative_to(root)): _sha256(f) for f in walk_sr_files(src_dir)}


def hash_pbl_dir(input_path: Path) -> dict[str, str]:
    """SHA256-hash every .pbl file under input_path. Keys are relative path strings."""
    path = input_path.resolve()
    return {str(p.name): _sha256(p) for p in sorted(path.iterdir()) if p.is_file() and p.suffix.lower() == ".pbl"}


def ensure_explorer_built(repo: Path, verbose: bool = False) -> None:
    """Ensure the explorer TypeScript bundle is up-to-date.

    Rebuilds the TypeScript bundle if any source file is newer than the bundle
    output. The prebuild step (pnpm prebuild) regenerates ast.generated.ts via
    cabal run pb-runner --emit-ts automatically when pnpm build is invoked.
    """
    ui_dir = repo / "ui"
    dist_js = repo / "cli" / "pb_cli" / "explorer" / "static" / "dist" / "App.js"

    if _bundle_stale(ui_dir, dist_js):
        print("Building explorer frontend...", file=sys.stderr)
        _run_explorer(ui_dir, ["pnpm", "install", "--frozen-lockfile"], verbose)
        _run_explorer(ui_dir, ["pnpm", "build"], verbose)
        if not dist_js.exists():
            sys.exit("error: explorer build produced no output")


def _bundle_stale(explorer_dir: "Path", dist_js: "Path") -> bool:
    if not dist_js.exists():
        return True
    cutoff = dist_js.stat().st_mtime
    for pattern in ["src/**/*.ts", "src/**/*.tsx", "package.json", "vite.config.ts"]:
        if any(f.stat().st_mtime > cutoff for f in explorer_dir.glob(pattern)):
            return True
    return False


def _run_explorer(explorer_dir: "Path", cmd: "list[str]", verbose: bool) -> None:
    r = subprocess.run(cmd, cwd=str(explorer_dir), capture_output=not verbose, text=True)
    if r.returncode != 0:
        if not verbose:
            print(r.stderr, file=sys.stderr)
        sys.exit(f"error: explorer build failed ({' '.join(cmd)})")


def build_subset_tmpdir(src_dir: Path, files: list[str]) -> Path:
    """
    Copy a subset of source files into a fresh tmpdir preserving relative paths.
    Uses hard links where possible, falls back to shutil.copy2 for cross-volume.
    Caller must clean up the returned directory (shutil.rmtree).
    """
    tmpdir = Path(tempfile.mkdtemp())
    for f in files:
        src = src_dir / f
        dst = tmpdir / f
        dst.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.link(src, dst)
        except OSError:
            shutil.copy2(src, dst)
    return tmpdir


def generate_ast_python(repo: Path, verbose: bool = False) -> None:
    """Generate pb_cli/core/ast_generated.py from Haskell code via pb-runner.

    This is called implicitly on first use (e.g., `pb explore`) when the file
    doesn't exist yet. The generation is a no-op if the file is already up-to-date.
    """
    ast_py = repo / "cli" / "pb_cli" / "core" / "ast_generated.py"
    parser_dir = repo / "parser"

    if ast_py.exists():
        return

    # Run cabal run pb-runner --emit-py to generate the Python AST types
    cmd = ["cabal", "run", "--project-dir", str(parser_dir), "pb-runner", "-v0", "--emit-py"]
    r = subprocess.run(
        cmd,
        cwd=str(parser_dir),
        capture_output=not verbose,
        text=True,
    )
    if r.returncode != 0:
        if not verbose:
            print(r.stderr, file=sys.stderr)
        sys.exit(f"error: failed to generate ast_generated.py ({' '.join(cmd)})")
    if not ast_py.exists():
        sys.exit(f"error: ast_generated.py was not created by {cmd}")
