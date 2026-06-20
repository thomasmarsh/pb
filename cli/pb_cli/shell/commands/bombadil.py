"""Bombadil test harness with stall detection.

Runs N simultaneous bombadil instances (default 2), monitors each for stalls,
and kills any that go quiet. All output goes to per-instance log files — the
terminal shows only the summary.

Usage:
    ./pb dev run
    ./pb dev run -n 4
    ./pb dev run --headed
    ./pb dev run --long
    ./pb dev run --stall-timeout 10
"""

import subprocess
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

import typer

from pb_cli.shell.env import env

app = typer.Typer(help="Run Bombadil with stall detection.")

LOG_DIR = Path("/tmp/bombadil-logs")


@dataclass
class Instance:
    index: int
    proc: subprocess.Popen | None = None
    log_path: Path = field(default_factory=Path)
    output_dir: Path = field(default_factory=Path)
    last_size: int = 0
    last_activity: float = 0.0
    stall_killed: bool = False
    violations: list[str] = field(default_factory=list)
    exit_code: int | None = None


def _tail_log(log_path: Path, n: int = 30) -> list[str]:
    """Return last n non-empty lines from the log."""
    if not log_path.exists():
        return []
    lines = log_path.read_text().splitlines()
    return [line for line in lines if line.strip()][-n:]


@app.command()
def run(
    headed: bool = typer.Option(False, "--headed", help="Run in headed (visible) mode."),
    long: bool = typer.Option(False, "--long", help="Long run — no exit-on-violation."),
    stall_timeout: int = typer.Option(15, "--stall-timeout", help="Seconds of no output before kill."),
    time_limit: str = typer.Option("5m", "--time-limit", help="Bombadil time limit (e.g. 5m, 10m)."),
    backend_url: str = typer.Option("http://localhost:8000", "--backend", help="Backend URL."),
    n: int = typer.Option(2, "-n", help="Number of simultaneous bombadil instances."),
) -> None:
    """Run N simultaneous bombadil instances with stall detection."""
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")

    repo_path = env.build.find_repo()
    ui_dir = repo_path / "ui"

    if headed:
        base_cmd = ["bombadil", "browser", "test", backend_url, "bombadil-spec.ts", "--exit-on-violation"]
    elif long:
        base_cmd = ["bombadil", "browser", "test", backend_url, "bombadil-spec.ts"]
    else:
        base_cmd = ["bombadil", "browser", "test", backend_url, "bombadil-spec.ts", "--headless", "--exit-on-violation"]

    # Launch N instances with separate output dirs and logs
    instances: list[Instance] = []
    for i in range(n):
        inst = Instance(
            index=i,
            log_path=LOG_DIR / f"bombadil-{ts}-{i}.log",
            output_dir=Path(f"/tmp/bombadil-pb-{i}"),
            last_activity=time.monotonic(),
        )
        inst.output_dir.mkdir(parents=True, exist_ok=True)

        cmd = base_cmd.copy()
        # Override --time-limit if specified (default "5m" matches the pnpm scripts)
        if "--time-limit" in cmd:
            idx = cmd.index("--time-limit")
            cmd[idx + 1] = time_limit
        else:
            cmd += ["--time-limit", time_limit]
        # Replace --output-path with per-instance dir
        if "--output-path" in cmd:
            idx = cmd.index("--output-path")
            cmd[idx + 1] = str(inst.output_dir)
        else:
            cmd += ["--output-path", str(inst.output_dir)]

        with open(inst.log_path, "w") as log_fh:
            inst.proc = subprocess.Popen(
                cmd,
                stdout=log_fh,
                stderr=subprocess.STDOUT,
                cwd=str(ui_dir),
            )
        instances.append(inst)

    typer.echo(f"Launched {n} bombadil instance(s) [stall: {stall_timeout}s]")
    for inst in instances:
        if inst.proc is not None:
            typer.echo(f"  [{inst.index}] PID {inst.proc.pid}  log: {inst.log_path}")

    # Monitor loop
    try:
        while any(inst.proc and inst.proc.poll() is None for inst in instances):
            now = time.monotonic()
            for inst in instances:
                if inst.proc is None or inst.proc.poll() is not None:
                    if inst.proc is not None and inst.exit_code is None:
                        inst.proc.wait()
                        inst.exit_code = inst.proc.returncode
                    continue

                # Check log file size growth as activity proxy
                try:
                    size = inst.log_path.stat().st_size
                except OSError:
                    size = 0

                if size != inst.last_size:
                    inst.last_size = size
                    inst.last_activity = now

                # Stall check
                if now - inst.last_activity > stall_timeout:
                    typer.echo(f"  [{inst.index}] STALL — killing PID {inst.proc.pid}")
                    inst.stall_killed = True
                    inst.proc.kill()
                    inst.proc.wait()
                    inst.exit_code = inst.proc.returncode
                    continue

            time.sleep(1)

    except KeyboardInterrupt:
        typer.echo("\nInterrupted — killing all instances...")
        for inst in instances:
            if inst.proc and inst.proc.poll() is None:
                inst.proc.kill()
                inst.proc.wait()

    # Parse results
    for inst in instances:
        if inst.proc:
            if inst.exit_code is None:
                inst.proc.wait()
                inst.exit_code = inst.proc.returncode
        if inst.log_path.exists():
            for line in inst.log_path.read_text().splitlines():
                if "was violated" in line:
                    inst.violations.append(line.strip())

    # Summary
    typer.echo(f"\n{'='*60}")
    total_violations = sum(len(inst.violations) for inst in instances)
    stalled = sum(1 for inst in instances if inst.stall_killed)
    errored = sum(1 for inst in instances if not inst.stall_killed and not inst.violations and inst.exit_code not in (None, 0))
    clean = sum(1 for inst in instances if not inst.stall_killed and not inst.violations and inst.exit_code in (None, 0))

    for inst in instances:
        if inst.stall_killed:
            status = "STALLED"
        elif inst.violations:
            status = f"{len(inst.violations)} violations"
        elif inst.exit_code not in (None, 0):
            status = f"ERROR (exit {inst.exit_code})"
        else:
            status = "CLEAN"
        typer.echo(f"  [{inst.index}] {status}  log: {inst.log_path}")

    typer.echo(f"\nTotal: {n} instances — {clean} clean, {stalled} stalled, {errored} errored, {total_violations} violations")

    # Show violations
    if total_violations:
        typer.echo("\nViolations:")
        for inst in instances:
            for v in inst.violations:
                typer.echo(f"  [{inst.index}] {v[:120]}")

    # Show stall tails
    if stalled:
        typer.echo("\nStall tails (last 10 lines):")
        for inst in instances:
            if inst.stall_killed:
                tail = _tail_log(inst.log_path, n=10)
                if tail:
                    typer.echo(f"  [{inst.index}]:")
                    for line in tail:
                        typer.echo(f"    {line}")
