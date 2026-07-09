"""Build management: find repo root, build pbc, enumerate source files."""

import hashlib
import re
import subprocess
import sys
import sysconfig
from pathlib import Path


def _find_ancestor_containing(start: Path, marker: Path) -> Path | None:
    """Walk `start` and its ancestors looking for one that has `marker` (a
    relative path) as a child. Returns the matching ancestor directory
    itself (not the marker path), or None if no ancestor has it."""
    for p in [start, *start.parents]:
        if (p / marker).exists():
            return p
    return None


def find_repo(repo: Path | None = None) -> Path:
    if repo:
        return repo
    found = _find_ancestor_containing(Path.cwd(), Path("compiler") / "pb-compiler.cabal")
    if found is not None:
        return found
    sys.exit(
        "error: cannot locate repo root (no compiler/pb-compiler.cabal found). Run from within the pb repo, or pass --repo."
    )


def get_queries_dir() -> Path:
    """Lazy accessor for the queries/ directory — avoids import-time find_repo()."""
    return find_repo() / "queries"


def find_binary(repo: Path) -> Path:
    """Return the compiled pbc binary path without triggering a build."""
    r = subprocess.run(
        ["cabal", "list-bin", "pbc"],
        cwd=str(repo / "compiler"),
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        sys.exit("error: cabal list-bin pbc failed — try without --no-build")
    binary = Path(r.stdout.strip())
    if not binary.exists():
        sys.exit(f"error: binary not found at {binary} — try without --no-build")
    return binary


def build_runner(repo: Path, verbose: bool = False) -> Path:
    """Build pbc via cabal and return the compiled binary path."""
    verbosity = [] if verbose else ["-v0"]
    r = subprocess.run(
        ["cabal", "build", "pbc"] + verbosity,
        cwd=str(repo / "compiler"),
        capture_output=not verbose,
        text=True,
    )
    if r.returncode != 0:
        if not verbose:
            print(r.stderr, file=sys.stderr)
        sys.exit(1)
    return find_binary(repo)


def find_sql_worker() -> Path | None:
    """Return the path to the pb-sql-worker script if it is installed, else
    None. pb-sql-worker is a console-script entry point in the same
    `pb_pipeline` distribution as `pb` itself, so pip/uv always install it
    into `sysconfig.get_path("scripts")` of whichever interpreter is
    currently running this code -- that's true by construction for any
    install layout (editable dev checkout, non-editable wheel, a venv
    named something other than `.venv`, a system/container Python with no
    venv at all), unlike searching ancestor directories for a marker path
    that assumes a specific on-disk structure. No configuration or
    environment variable should ever be needed to find it (real bug
    report, 2026-07-09: an earlier ancestor-walk-for-`.venv` version
    depended on the venv literally being named `.venv` and reachable from
    this file's install location, which doesn't hold for every deployment
    shape)."""
    scripts_dir = Path(sysconfig.get_path("scripts"))
    for name in ("pb-sql-worker", "pb-sql-worker.exe"):
        candidate = scripts_dir / name
        if candidate.exists():
            return candidate
    # Last-resort fallback: PATH (e.g. scripts_dir wasn't used for the
    # install that put pb-sql-worker somewhere else reachable another way).
    import shutil
    found = shutil.which("pb-sql-worker")
    return Path(found) if found else None


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
    cabal run pbc --emit-ts automatically when pnpm build is invoked.
    """
    ui_dir = repo / "ui"
    dist_js = repo / "cli" / "api" / "src" / "pb" / "api" / "static" / "dist" / "App.js"

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


