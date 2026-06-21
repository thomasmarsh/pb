"""Stream parse results from pb-runner --jsonl, with rich error rendering."""

import json
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Iterator

from rich.panel import Panel
from rich.text import Text

_LINE_RE = re.compile(r"\bline[: ]+(\d+)", re.IGNORECASE)
_CTX = 3


def extract_line(msg: str) -> int | None:
    m = _LINE_RE.search(msg)
    return int(m.group(1)) if m else None


def _context(file_path: str, line_no: int | None) -> str | None:
    try:
        lines = Path(file_path).read_text(errors="replace").splitlines()
    except OSError:
        return None
    if not lines:
        return None
    if line_no is None:
        snippet = lines[: min(6, len(lines))]
        return "\n".join(f"   {i + 1:4d}  {ln}" for i, ln in enumerate(snippet))
    lo = max(0, line_no - _CTX - 1)
    hi = min(len(lines), line_no + _CTX)
    out = []
    for i in range(lo, hi):
        pfx = "→" if i == line_no - 1 else " "
        out.append(f"  {pfx} {i + 1:4d}  {lines[i]}")
    return "\n".join(out)


def render_error(obj: dict) -> Panel:
    """Build a rich Panel for a single parse-error JSON object."""
    fp = obj.get("file", "<unknown>")
    msg = obj.get("error", "<no message>")
    ctx = _context(fp, extract_line(msg))
    t = Text()
    t.append(f"{fp}\n", style="bold yellow")
    t.append(msg, style="red")
    if ctx:
        t.append("\n\n")
        t.append(ctx, style="dim white")
    return Panel(t, title="[red bold]parse error[/red bold]", border_style="red", expand=False)


def parse_stream(
    src_dir: Path,
    binary: Path,
    *,
    remap_from: Path | None = None,
    remap_to: Path | None = None,
) -> Iterator[tuple[bool, dict]]:
    """
    Run pb-runner --jsonl on src_dir and yield (is_error, obj) for every file.

    If remap_from/remap_to are set, rewrites obj['file'] from remap_from-rooted
    paths back to remap_to-rooted paths (used when parsing a subset tmpdir).
    """
    proc = subprocess.Popen(
        [str(binary), "-i", str(src_dir), "--jsonl"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )
    if proc.stdout is None:
        proc.wait()
        return
    try:
        for raw in proc.stdout:
            raw = raw.strip()
            if not raw:
                continue
            try:
                obj = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if remap_from and remap_to and "file" in obj:
                try:
                    rel = Path(obj["file"]).relative_to(remap_from)
                    obj["file"] = str(remap_to / rel)
                except ValueError:
                    pass
            yield obj.get("kind") == "error", obj
    finally:
        proc.stdout.close()
        proc.wait()


def parse_files(
    src_dir: Path,
    binary: Path,
    *,
    remap_from: Path | None = None,
    remap_to: Path | None = None,
) -> tuple[Iterator[tuple[bool, dict]], Path]:
    """
    Run pb-runner -o out_dir on src_dir and return an iterator of (is_error, obj)
    plus the output directory path (for reading taint/def/use JSON files).

    If remap_from/remap_to are set, rewrites obj['file'] from remap_from-rooted
    paths back to remap_to-rooted paths (used when parsing a subset tmpdir).
    """
    out_dir = Path(tempfile.mkdtemp(prefix="pb-runner-"))
    proc = subprocess.run(
        [str(binary), "-i", str(src_dir), "-o", str(out_dir)],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        # pb-runner failed — yield the error as a single object
        def _err_iter() -> Iterator[tuple[bool, dict]]:
            yield (True, {"file": str(src_dir), "kind": "error",
                          "error": proc.stderr[:500] if proc.stderr else "pb-runner failed"})
        return _err_iter(), out_dir

    # Read per-file JSON from outDir (skip root-level analysis arrays)
    def _iter() -> Iterator[tuple[bool, dict]]:
        for json_path in sorted(out_dir.rglob("*.json")):
            # Skip root-level analysis files (arrays) and manifest
            if json_path.parent == out_dir or json_path.name == "manifest.json":
                continue
            try:
                obj = json.loads(json_path.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                continue
            if not isinstance(obj, dict):
                continue
            if remap_from and remap_to and "file" in obj:
                try:
                    rel = Path(obj["file"]).relative_to(remap_from)
                    obj["file"] = str(remap_to / rel)
                except ValueError:
                    pass
            yield obj.get("kind") == "error", obj

    return _iter(), out_dir
