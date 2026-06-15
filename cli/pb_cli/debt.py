"""Analyze BsRaw + ExRaw debt and DW control coverage across both corpora."""
import json
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

from pb_cli.build import build_runner, find_binary, find_repo

SQL_KWS = {
    "select", "selectblob", "insert", "update", "updateblob", "delete",
    "commit", "rollback", "connect", "disconnect", "declare", "cursor",
    "execute", "fetch", "prepare", "describe", "descriptor",
    "from", "and", "or", "into", "using", "where", "having",
    "group", "order", "join", "open", "close",
}
CTRL_KWS = {
    "if", "else", "elseif", "end", "choose", "case",
    "for", "do", "loop", "while", "until",
    "try", "catch", "finally",
}
DECL_KWS = {
    "event", "on", "function", "subroutine", "type",
    "variables", "forward", "prototypes",
}
HANDLED = {"return", "exit", "continue", "call", "destroy", "create", "halt"}

DW_STRUCT_FIELDS = ["name", "band", "id", "x", "y", "width", "height",
                    "visible", "expression", "tab_seq"]


# ── AST walkers ───────────────────────────────────────────────────────────────

def walk_bsraw(node):
    if isinstance(node, list):
        for x in node:
            yield from walk_bsraw(x)
    elif isinstance(node, dict):
        if node.get("tag") == "BsRaw":
            text = node.get("contents", "")
            if isinstance(text, str):
                yield text
        for v in node.values():
            if isinstance(v, (dict, list)):
                yield from walk_bsraw(v)


def walk_exraw(node):
    if isinstance(node, list):
        for x in node:
            yield from walk_exraw(x)
    elif isinstance(node, dict):
        if node.get("tag") == "ExRaw":
            toks = node.get("contents", [])
            if toks:
                yield toks[0], toks
        for v in node.values():
            if isinstance(v, (dict, list)):
                yield from walk_exraw(v)


def categorize(text: str) -> tuple[str, str]:
    words = text.strip().split()
    if not words:
        return "empty", ""
    first = words[0].lower().rstrip(";")
    if first in SQL_KWS:
        return "sql", first
    if first in CTRL_KWS:
        return "ctrl", first
    if first in DECL_KWS:
        return "decl", first
    if first in HANDLED or first.endswith(":"):
        return "handled", first
    if text.strip().startswith("{"):
        return "array_init", first
    return "other", first


# ── Analysis dataclasses ──────────────────────────────────────────────────────

@dataclass
class BsRawStats:
    bsraw_total:  int = 0
    exraw_total:  int = 0
    counts:       Counter[str] = field(default_factory=Counter)
    other:        Counter[str] = field(default_factory=Counter)
    other_ex:     dict[str, list[str]] = field(default_factory=lambda: defaultdict(list))
    exraw_words:  Counter[str] = field(default_factory=Counter)
    exraw_ex:     dict[str, list[str]] = field(default_factory=lambda: defaultdict(list))


@dataclass
class DwStats:
    files:  int = 0
    total:  int = 0
    fields: Counter[str] = field(default_factory=Counter)
    types:  Counter[str] = field(default_factory=Counter)


# ── Per-directory analysis ────────────────────────────────────────────────────

def _load_dicts(out_dir: Path):
    for path in out_dir.rglob("*.json"):
        try:
            with open(path) as fh:
                d = json.load(fh)
            if isinstance(d, dict) and "error" not in d:
                yield d
        except Exception:
            continue


def _analyze_bsraw(out_dir: Path) -> BsRawStats:
    s = BsRawStats()
    for d in _load_dicts(out_dir):
        for text in walk_bsraw(d):
            s.bsraw_total += 1
            cat, key = categorize(text)
            s.counts[cat] += 1
            if cat == "other":
                s.other[key] += 1
                if len(s.other_ex[key]) < 3:
                    s.other_ex[key].append(text.strip()[:100])
        for first, toks in walk_exraw(d):
            s.exraw_total += 1
            key = first.lower().rstrip(";(")
            s.exraw_words[key] += 1
            if len(s.exraw_ex[key]) < 3:
                s.exraw_ex[key].append(" ".join(toks[:8]))
    return s


def _analyze_dw(out_dir: Path) -> DwStats:
    s = DwStats()
    for d in _load_dicts(out_dir):
        if d.get("kind") != "datawindow":
            continue
        s.files += 1
        for ctrl in d.get("controls", []):
            s.total += 1
            s.types[ctrl.get("type", "?")] += 1
            for f in DW_STRUCT_FIELDS:
                if ctrl.get(f) is not None:
                    s.fields[f] += 1
    return s


# ── Report printers ───────────────────────────────────────────────────────────

def _pct(n: int, total: int) -> str:
    return f"{n / total * 100:5.1f}%" if total else "   n/a"


def _print_bsraw_report(corpora: list[tuple[str, Path]]) -> None:
    grand = BsRawStats()

    for name, out_dir in corpora:
        s = _analyze_bsraw(out_dir)
        files = sum(1 for _ in out_dir.rglob("*.json"))
        print(f"=== {name}: {files} files, {s.bsraw_total} BsRaw, {s.exraw_total} ExRaw ===")
        for cat in ("sql", "decl", "ctrl", "handled", "array_init", "other"):
            n = s.counts.get(cat, 0)
            if n:
                print(f"  {cat:12s} {n:5d}")
        print()

        grand.bsraw_total += s.bsraw_total
        grand.exraw_total += s.exraw_total
        grand.other += s.other
        grand.exraw_words += s.exraw_words
        for w, exs in s.other_ex.items():
            for ex in exs:
                if len(grand.other_ex[w]) < 3:
                    grand.other_ex[w].append(ex)
        for w, exs in s.exraw_ex.items():
            for ex in exs:
                if len(grand.exraw_ex[w]) < 3:
                    grand.exraw_ex[w].append(ex)

    other_total = sum(grand.other.values())
    print(f"=== TOTALS: {grand.bsraw_total} BsRaw, {grand.exraw_total} ExRaw across both corpora ===")
    print(f"    BsRaw 'other' (actionable): {other_total}")
    print()

    if grand.other:
        print("BsRaw 'other' breakdown (not SQL/ctrl/decl/handled/array_init):")
        for word, count in grand.other.most_common(40):
            print(f"  {word!r:42s}  {count:5d}")
            for ex in grand.other_ex[word][:2]:
                print(f"      {ex!r}")
        print()

    if grand.exraw_words:
        print(f"ExRaw breakdown by leading token (top 40, total {grand.exraw_total}):")
        for word, count in grand.exraw_words.most_common(40):
            print(f"  {word!r:42s}  {count:5d}")
            for ex in grand.exraw_ex[word][:2]:
                print(f"      {ex!r}")


def _print_dw_report(corpora: list[tuple[str, Path]]) -> None:
    print("=== DW Control Coverage ===")
    grand = DwStats()

    for name, out_dir in corpora:
        s = _analyze_dw(out_dir)
        grand.files += s.files
        grand.total += s.total
        grand.fields += s.fields
        grand.types  += s.types
        print(f"  {name}: {s.files} DW files, {s.total} controls")
        for f in DW_STRUCT_FIELDS:
            n = s.fields.get(f, 0)
            print(f"    {f:12s}  {n:5d} / {s.total}  ({_pct(n, s.total)})")

    if grand.total:
        print(f"  TOTAL: {grand.files} DW files, {grand.total} controls")
        for f in DW_STRUCT_FIELDS:
            n = grand.fields.get(f, 0)
            print(f"    {f:12s}  {n:5d} / {grand.total}  ({_pct(n, grand.total)})")
        print()
        print("  Control types (top 15):")
        for typ, cnt in grand.types.most_common(15):
            print(f"    {typ:20s}  {cnt:5d}")


# ── Entry point ───────────────────────────────────────────────────────────────

def run(repo: Path | None = None, no_build: bool = False) -> None:
    repo_path = find_repo(repo)
    if not no_build:
        print("Building pb-runner...", flush=True)
        binary = build_runner(repo_path)
    else:
        binary = find_binary(repo_path)

    corpus_srcs = [
        ("Appeon",  repo_path / "example" / "PowerBuilder-Example" / "export"),
        ("OpenPay", repo_path / "example" / "openpay-src"),
    ]

    with tempfile.TemporaryDirectory() as tmp:
        corpora: list[tuple[str, Path]] = []
        for name, src in corpus_srcs:
            out = Path(tmp) / name.lower()
            out.mkdir()
            print(f"Running {name} corpus...", flush=True)
            r = subprocess.run(
                [str(binary), "-i", str(src), "-o", str(out)],
                capture_output=True, text=True,
            )
            if r.returncode != 0:
                print(f"[ERROR] pb-runner failed on {name}:\n{r.stderr[:400]}", file=sys.stderr)
                sys.exit(1)
            corpora.append((name, out))

        print()
        _print_bsraw_report(corpora)
        print()
        _print_dw_report(corpora)
