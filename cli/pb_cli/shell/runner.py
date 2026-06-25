"""Error rendering helpers for pbc output."""

import re
from pathlib import Path

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
