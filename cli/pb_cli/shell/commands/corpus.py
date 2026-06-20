"""Run pb-runner on both corpora and fail if any files contain parse errors."""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

from pb_cli.shell.env import env


def run(repo: Path | None = None, no_build: bool = False) -> None:
    """Run pb-runner on both corpora and fail if any files contain errors."""
    repo_path = env.build.find_repo(repo)
    if not no_build:
        print("Building pb-runner...", flush=True)
        binary = env.build.build_runner(repo_path)
    else:
        binary = env.build.find_binary(repo_path)

    corpus_srcs = [
        ("Appeon", repo_path / "example" / "PowerBuilder-Example-extract"),
        ("OpenPay", repo_path / "example" / "openpay-0.1.1b-extract"),
    ]

    total = 0
    errors = 0
    failing: list[str] = []

    with tempfile.TemporaryDirectory() as tmp:
        for name, src in corpus_srcs:
            if not src.exists():
                print(f"Skipping {name}: {src} not found", flush=True)
                continue
            out = Path(tmp) / name.lower()
            out.mkdir()
            print(f"Processing {name} corpus...", flush=True)
            r = subprocess.run(
                [str(binary), "-i", str(src), "-o", str(out)],
                capture_output=True,
                text=True,
            )
            if r.returncode != 0:
                print(f"[ERROR] pb-runner failed on {name}:\n{r.stderr[:400]}", file=sys.stderr)
                sys.exit(1)
            for f in out.rglob("*.json"):
                total += 1
                try:
                    d = json.loads(f.read_text())
                    if "error" in d:
                        errors += 1
                        failing.append(str(f))
                except (json.JSONDecodeError, OSError):
                    errors += 1
                    failing.append(str(f) + " (decode error)")

    print()
    print(f"Files processed: {total}  |  Errors: {errors}")

    if errors > 0:
        print()
        print("--- failing files ---")
        for path in failing:
            print(path)
        sys.exit(1)
