"""Run pb-runner on both corpora and fail if any files contain parse errors."""

import subprocess
import sys
import tempfile
from pathlib import Path

import duckdb

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
            db_path = Path(tmp) / f"{name.lower()}.duckdb"
            print(f"Processing {name} corpus...", flush=True)
            r = subprocess.run(
                [str(binary), "-i", str(src), "--db", str(db_path)],
                capture_output=True,
                text=True,
            )
            if r.returncode != 0:
                print(f"[ERROR] pb-runner failed on {name}:\n{r.stderr[:400]}", file=sys.stderr)
                sys.exit(1)
            con = duckdb.connect(str(db_path), read_only=True)
            n_ps  = con.execute("SELECT count(*) FROM objects").fetchone()[0]       # type: ignore[index]
            n_dw  = con.execute("SELECT count(*) FROM dw_objects").fetchone()[0]    # type: ignore[index]
            n_err = con.execute("SELECT count(*) FROM parse_errors").fetchone()[0]  # type: ignore[index]
            rows  = con.execute("SELECT file, error FROM parse_errors").fetchall()
            con.close()
            total  += n_ps + n_dw + n_err
            errors += n_err
            for file_, msg in rows:
                failing.append(f"{file_}: {msg[:120]}")

    print()
    print(f"Files processed: {total}  |  Errors: {errors}")

    if errors > 0:
        print()
        print("--- failing files ---")
        for entry in failing:
            print(entry)
        sys.exit(1)
