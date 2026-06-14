"""Build management: find repo root, build pb-runner, enumerate source files."""
import re
import subprocess
import sys
from pathlib import Path


def find_repo(repo: Path | None = None) -> Path:
    if repo:
        return repo
    for p in [Path.cwd(), *Path.cwd().parents]:
        if (p / "pb-ast.cabal").exists():
            return p
    sys.exit(
        "error: cannot locate repo root (no pb-ast.cabal found). "
        "Run from within the pb repo, or pass --repo."
    )


def find_binary(repo: Path) -> Path:
    """Return the compiled pb-runner binary path without triggering a build."""
    r = subprocess.run(
        ["cabal", "list-bin", "pb-runner"],
        cwd=str(repo),
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
        cwd=str(repo),
        capture_output=not verbose,
        text=True,
    )
    if r.returncode != 0:
        if not verbose:
            print(r.stderr, file=sys.stderr)
        sys.exit(1)
    return find_binary(repo)


_SR_EXT = re.compile(r'\.sr[a-z]$', re.IGNORECASE)


def walk_sr_files(src_dir: Path) -> list[Path]:
    """Return all .sr<x> source files under src_dir as absolute Paths."""
    root = Path(src_dir).resolve()
    return [f for f in root.rglob('*') if f.is_file() and _SR_EXT.search(f.name)]


def count_sr_files(src_dir: Path) -> int:
    return len(walk_sr_files(src_dir))


def ensure_explorer_built(repo: Path, verbose: bool = False) -> None:
    """Ensure the explorer TypeScript bundle is up-to-date.

    Rebuilds the TypeScript bundle if any source file is newer than the bundle
    output. The prebuild step (pnpm prebuild) regenerates ast.generated.ts via
    cabal run pb-runner --emit-ts automatically when pnpm build is invoked.
    """
    ui_dir  = repo / "ui"
    dist_js = repo / "pbtools" / "explorer" / "static" / "dist" / "app.js"

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
    r = subprocess.run(cmd, cwd=str(explorer_dir),
                       capture_output=not verbose, text=True)
    if r.returncode != 0:
        if not verbose:
            print(r.stderr, file=sys.stderr)
        sys.exit(f"error: explorer build failed ({' '.join(cmd)})")
