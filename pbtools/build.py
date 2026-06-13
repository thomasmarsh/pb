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
    """Ensure the TypeScript explorer is built. Runs pnpm install + build if needed."""
    dist_js = repo / "pbtools" / "explorer" / "static" / "dist" / "app.js"
    if dist_js.exists():
        return
    explorer_dir = repo / "pbtools" / "explorer"
    if not (explorer_dir / "package.json").exists():
        sys.exit("error: pbtools/explorer/package.json not found — cannot auto-build explorer")
    print("Building explorer frontend...", file=sys.stderr)
    for cmd in [["pnpm", "install", "--frozen-lockfile"], ["pnpm", "build"]]:
        r = subprocess.run(
            cmd,
            cwd=str(explorer_dir),
            capture_output=not verbose,
            text=True,
        )
        if r.returncode != 0:
            if not verbose:
                print(r.stderr, file=sys.stderr)
            sys.exit(f"error: explorer build failed ({' '.join(cmd)})")
    if not dist_js.exists():
        sys.exit("error: explorer build produced no output")
