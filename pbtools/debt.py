"""
pb debt — analyze BsRaw + ExRaw debt and DW control coverage across both corpora.

Usage (CLI):
    pb debt [--no-build] [--repo PATH]

Library:
    from pbtools.debt import run
"""
import glob
import json
import os
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from pathlib import Path

from pbtools.build import build_runner, find_binary, find_repo

SQL_KWS = {
    "select", "selectblob", "insert", "update", "updateblob", "delete",
    "commit", "rollback", "connect", "disconnect", "declare", "cursor",
    "execute", "fetch", "prepare", "describe", "descriptor",
    "from", "and", "or", "into", "using", "where", "having",
    "group", "order", "join",
    "open", "close",
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


def walk_bsraw(node):
    if isinstance(node, list):
        for x in node:
            yield from walk_bsraw(x)
    elif isinstance(node, dict):
        if node.get("tag") == "raw" and "text" in node:
            yield node["text"]
        for v in node.values():
            if isinstance(v, (dict, list)):
                yield from walk_bsraw(v)


def walk_exraw(node):
    if isinstance(node, list):
        for x in node:
            yield from walk_exraw(x)
    elif isinstance(node, dict):
        if node.get("tag") == "raw" and "tokens" in node:
            toks = node["tokens"]
            if toks:
                yield toks[0], toks
        for v in node.values():
            if isinstance(v, (dict, list)):
                yield from walk_exraw(v)


def categorize(text):
    txt   = text.strip()
    words = txt.split()
    if not words:
        return "empty", ""
    first = words[0].lower().rstrip(";")
    if first in SQL_KWS:      return "sql",        first
    if first in CTRL_KWS:     return "ctrl",       first
    if first in DECL_KWS:     return "decl",       first
    if first in HANDLED:      return "handled",    first
    if first.endswith(":"):   return "handled",    first
    if txt.startswith("{"):   return "array_init", first
    return "other", first


def run_corpus(name: str, src_dir: str, out_dir: str, binary: Path) -> None:
    r = subprocess.run(
        [str(binary), "-i", src_dir, "-o", out_dir],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        print(f"[ERROR] pb-runner failed on {name}:\n{r.stderr[:400]}", file=sys.stderr)
        sys.exit(1)


def analyze_dir(out_dir: str):
    counts       = Counter()
    other_words  = Counter()
    examples     = defaultdict(list)
    total        = 0
    exraw_total  = 0
    exraw_words  = Counter()
    exraw_examples = defaultdict(list)
    for f in glob.glob(os.path.join(out_dir, "**", "*.json"), recursive=True):
        try:
            d = json.load(open(f))
        except Exception:
            continue
        if not isinstance(d, dict) or "error" in d:
            continue
        for text in walk_bsraw(d):
            total += 1
            cat, key = categorize(text)
            counts[cat] += 1
            if cat == "other":
                other_words[key] += 1
                if len(examples[key]) < 3:
                    examples[key].append(text.strip()[:100])
        for first, toks in walk_exraw(d):
            exraw_total += 1
            key = first.lower().rstrip(";(")
            exraw_words[key] += 1
            if len(exraw_examples[key]) < 3:
                exraw_examples[key].append(" ".join(toks[:8]))
    return total, counts, other_words, examples, exraw_total, exraw_words, exraw_examples


def analyze_dw_controls(out_dir: str):
    dw_files = 0
    total    = 0
    field_counts = Counter()
    type_counts  = Counter()
    for f in glob.glob(os.path.join(out_dir, "**", "*.json"), recursive=True):
        try:
            d = json.load(open(f))
        except Exception:
            continue
        if not isinstance(d, dict) or d.get("kind") != "datawindow" or "error" in d:
            continue
        dw_files += 1
        for ctrl in d.get("controls", []):
            total += 1
            type_counts[ctrl.get("type", "?")] += 1
            for field in DW_STRUCT_FIELDS:
                if ctrl.get(field) is not None:
                    field_counts[field] += 1
    return dw_files, total, field_counts, type_counts


def run(repo: Path | None = None, no_build: bool = False) -> None:
    repo_path = find_repo(repo)
    appeon  = str(repo_path / "example" / "PowerBuilder-Example" / "export")
    openpay = str(repo_path / "example" / "openpay")

    if not no_build:
        print("Building pb-runner...", flush=True)
        binary = build_runner(repo_path)
    else:
        binary = find_binary(repo_path)

    with tempfile.TemporaryDirectory() as tmp:
        appeon_out  = os.path.join(tmp, "appeon")
        openpay_out = os.path.join(tmp, "openpay")
        os.makedirs(appeon_out)
        os.makedirs(openpay_out)

        print("Running Appeon corpus...",  flush=True)
        run_corpus("appeon",  appeon,  appeon_out,  binary)
        print("Running OpenPay corpus...", flush=True)
        run_corpus("openpay", openpay, openpay_out, binary)
        print()

        grand_total        = 0
        all_other_words    = Counter()
        all_examples       = defaultdict(list)
        grand_exraw        = 0
        all_exraw_words    = Counter()
        all_exraw_examples = defaultdict(list)

        for name, out_dir in [("Appeon", appeon_out), ("OpenPay", openpay_out)]:
            total, counts, other_words, examples, exraw_total, exraw_words, exraw_examples \
                = analyze_dir(out_dir)
            grand_total  += total
            grand_exraw  += exraw_total
            files = len(list(glob.glob(os.path.join(out_dir, "**", "*.json"), recursive=True)))
            print(f"=== {name}: {files} files, {total} BsRaw, {exraw_total} ExRaw ===")
            for cat in ("sql", "decl", "ctrl", "handled", "array_init", "other"):
                n = counts.get(cat, 0)
                if n:
                    print(f"  {cat:12s} {n:5d}")
            print()
            for w, c in other_words.most_common():
                all_other_words[w] += c
                for ex in examples[w]:
                    if len(all_examples[w]) < 3:
                        all_examples[w].append(ex)
            for w, c in exraw_words.most_common():
                all_exraw_words[w] += c
                for ex in exraw_examples[w]:
                    if len(all_exraw_examples[w]) < 3:
                        all_exraw_examples[w].append(ex)

        other_total = sum(all_other_words.values())
        print(f"=== TOTALS: {grand_total} BsRaw, {grand_exraw} ExRaw across both corpora ===")
        print(f"    BsRaw 'other' (actionable): {other_total}")
        print()
        if all_other_words:
            print("BsRaw 'other' breakdown (not SQL/ctrl/decl/handled/array_init):")
            for word, count in all_other_words.most_common(40):
                print(f"  {word!r:42s}  {count:5d}")
                for ex in all_examples[word][:2]:
                    print(f"      {ex!r}")
            print()
        if all_exraw_words:
            print(f"ExRaw breakdown by leading token (top 40, total {grand_exraw}):")
            for word, count in all_exraw_words.most_common(40):
                print(f"  {word!r:42s}  {count:5d}")
                for ex in all_exraw_examples[word][:2]:
                    print(f"      {ex!r}")

        print()
        print("=== DW Control Coverage ===")
        grand_dw_files    = 0
        grand_dw_controls = 0
        grand_field_counts = Counter()
        grand_type_counts  = Counter()
        for name, out_dir in [("Appeon", appeon_out), ("OpenPay", openpay_out)]:
            dw_files, total, field_counts, type_counts = analyze_dw_controls(out_dir)
            grand_dw_files    += dw_files
            grand_dw_controls += total
            grand_field_counts += field_counts
            grand_type_counts  += type_counts
            pct = lambda n: f"{n/total*100:5.1f}%" if total else "   n/a"
            print(f"  {name}: {dw_files} DW files, {total} controls")
            for field in DW_STRUCT_FIELDS:
                n = field_counts.get(field, 0)
                print(f"    {field:12s}  {n:5d} / {total}  ({pct(n)})")
        if grand_dw_controls:
            print(f"  TOTAL: {grand_dw_files} DW files, {grand_dw_controls} controls")
            pct = lambda n: f"{n/grand_dw_controls*100:5.1f}%"
            for field in DW_STRUCT_FIELDS:
                n = grand_field_counts.get(field, 0)
                print(f"    {field:12s}  {n:5d} / {grand_dw_controls}  ({pct(n)})")
            print()
            print("  Control types (top 15):")
            for typ, cnt in grand_type_counts.most_common(15):
                print(f"    {typ:20s}  {cnt:5d}")
