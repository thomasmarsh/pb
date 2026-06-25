"""Remove build artifacts: cabal dist-newstyle, ui node_modules/built assets, Python caches/.venv."""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

from pb.pipeline.env import env

ALL_TARGETS = ["cabal", "ui", "python", "venv"]


def _rmtree(path: Path) -> bool:
    if not path.exists():
        return False
    shutil.rmtree(path, ignore_errors=True)
    return True


def _clean_cabal(repo: Path) -> list[str]:
    """cabal.project lives at the repo root (packages: compiler), so dist-newstyle
    is created there regardless of which subdirectory `cabal` is invoked from."""
    removed: list[str] = []
    r = subprocess.run(["cabal", "clean"], cwd=str(repo), capture_output=True, text=True)
    if r.returncode == 0:
        removed.append(f"{repo / 'dist-newstyle'} (via cabal clean)")
    else:
        print(f"[warn] cabal clean failed: {r.stderr.strip()[:300]}", file=sys.stderr)
    # Stray leftover from an older invocation pattern that ran cabal from compiler/
    # directly — harmless to remove if present.
    if _rmtree(repo / "compiler" / "dist-newstyle"):
        removed.append(str(repo / "compiler" / "dist-newstyle"))
    return removed


def _clean_ui(repo: Path) -> list[str]:
    removed: list[str] = []
    for rel in ("ui/node_modules", "cli/api/src/pb/api/static/dist"):
        if _rmtree(repo / rel):
            removed.append(str(repo / rel))
    return removed


def _clean_python_caches(repo: Path) -> list[str]:
    removed: list[str] = []
    for base in (repo, repo / "cli"):
        for name in (".pytest_cache", ".ruff_cache", ".mypy_cache"):
            if _rmtree(base / name):
                removed.append(str(base / name))
    for pycache in repo.rglob("__pycache__"):
        if "node_modules" in pycache.parts or "dist-newstyle" in pycache.parts or ".venv" in pycache.parts:
            continue
        if _rmtree(pycache):
            removed.append(str(pycache))
    return removed


def _clean_venv(repo: Path) -> list[str]:
    """Remove the Python virtualenv(s) — including, possibly, the one this very
    process is running from: `./pb` shells out via `uv run --project cli pb`,
    so `cli/.venv` holds the interpreter and modules currently executing this
    command. On POSIX, unlinking files a process still has open is safe (the
    inode stays alive until the process exits) — this is run last, and nothing
    is imported afterward. On Windows this would fail to remove open files;
    callers should expect a partial removal there and re-run once `pb` has exited.
    """
    removed: list[str] = []
    for rel in (".venv", "cli/.venv"):
        if _rmtree(repo / rel):
            removed.append(str(repo / rel))
    return removed


def run(repo: Path | None = None, targets: list[str] | None = None) -> None:
    repo_path = env.build.find_repo(repo)
    targets = targets or ALL_TARGETS
    unknown = set(targets) - set(ALL_TARGETS)
    if unknown:
        sys.exit(f"error: unknown clean target(s) {sorted(unknown)} — choose from {ALL_TARGETS}")

    removed: list[str] = []
    if "cabal" in targets:
        removed += _clean_cabal(repo_path)
    if "ui" in targets:
        removed += _clean_ui(repo_path)
    if "python" in targets:
        removed += _clean_python_caches(repo_path)
    if "venv" in targets:
        # Last: may delete the venv this process is currently running from.
        removed += _clean_venv(repo_path)

    if removed:
        print("Removed:")
        for r in removed:
            print(f"  {r}")
    else:
        print("Nothing to clean.")
