#!/usr/bin/env python3
"""
Categorize BsRaw body statements across both corpora.

Usage:
    python3 scripts/analyze-bsraw.py            # build + run
    python3 scripts/analyze-bsraw.py --no-build # skip cabal build

Output: per-corpus category counts and a combined 'other' breakdown with
examples. Use this at Stage 0 for any charter targeting BsRaw reduction.
"""
import argparse, json, os, glob, subprocess, sys, tempfile
from collections import Counter, defaultdict

REPO    = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APPEON  = os.path.join(REPO, "example", "PowerBuilder-Example", "export")
OPENPAY = os.path.join(REPO, "example", "openpay")

# Leading-word sets used for categorization (lower-cased, semicolons stripped).
# Keep in sync with Lexer.hs sqlKws / controlKws / declKws / otherKws.
# Note: "open" and "close" are intentionally excluded here — they appear both
# as SQL cursor ops ("OPEN DYNAMIC cur") and PowerScript calls ("open(w_main)").
# Both land in "other" so the examples reveal which is which.
SQL_KWS = {
    "select", "selectblob", "insert", "update", "updateblob", "delete",
    "commit", "rollback", "connect", "disconnect", "declare", "cursor",
    "execute", "fetch", "prepare", "describe", "descriptor",
    "from", "and", "or", "into", "using", "where", "having",
    "group", "order", "join",
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


def categorize(text):
    txt   = text.strip()
    words = txt.split()
    if not words:
        return "empty", ""
    first = words[0].lower().rstrip(";")
    if first in SQL_KWS:    return "sql",        first
    if first in CTRL_KWS:   return "ctrl",       first
    if first in DECL_KWS:   return "decl",       first
    if first in HANDLED:    return "handled",    first
    if txt.startswith("{"):  return "array_init", first
    return "other", first


def run_corpus(name, src_dir, out_dir):
    r = subprocess.run(
        ["cabal", "run", "pb-runner", "-v0", "--", "-i", src_dir, "-o", out_dir],
        capture_output=True, text=True, cwd=REPO,
    )
    if r.returncode != 0:
        print(f"[ERROR] pb-runner failed on {name}:\n{r.stderr[:400]}", file=sys.stderr)
        sys.exit(1)


def analyze_dir(out_dir):
    counts      = Counter()
    other_words = Counter()
    examples    = defaultdict(list)
    total       = 0
    for f in glob.glob(os.path.join(out_dir, "**", "*.json"), recursive=True):
        try:
            d = json.load(open(f))
        except Exception:
            continue
        if "error" in d:
            continue
        for text in walk_bsraw(d):
            total += 1
            cat, key = categorize(text)
            counts[cat] += 1
            if cat == "other":
                other_words[key] += 1
                if len(examples[key]) < 3:
                    examples[key].append(text.strip()[:100])
    return total, counts, other_words, examples


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--no-build", action="store_true", help="Skip cabal build")
    args = p.parse_args()

    if not args.no_build:
        print("Building pb-runner...", flush=True)
        r = subprocess.run(["cabal", "build", "pb-runner", "-v0"],
                           cwd=REPO, capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stderr, file=sys.stderr)
            sys.exit(1)

    with tempfile.TemporaryDirectory() as tmp:
        appeon_out  = os.path.join(tmp, "appeon")
        openpay_out = os.path.join(tmp, "openpay")
        os.makedirs(appeon_out)
        os.makedirs(openpay_out)

        print("Running Appeon corpus...",  flush=True)
        run_corpus("appeon",  APPEON,  appeon_out)
        print("Running OpenPay corpus...", flush=True)
        run_corpus("openpay", OPENPAY, openpay_out)
        print()

        grand_total     = 0
        all_other_words = Counter()
        all_examples    = defaultdict(list)

        for name, out_dir in [("Appeon", appeon_out), ("OpenPay", openpay_out)]:
            total, counts, other_words, examples = analyze_dir(out_dir)
            grand_total += total
            files = len(list(glob.glob(os.path.join(out_dir, "**", "*.json"),
                                       recursive=True)))
            print(f"=== {name}: {files} files, {total} BsRaw ===")
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

        other_total = sum(all_other_words.values())
        print(f"=== TOTALS: {grand_total} BsRaw across both corpora ===")
        print(f"    'other' (actionable): {other_total}")
        print()
        if all_other_words:
            print("'Other' breakdown (not SQL/ctrl/decl/handled/array_init):")
            for word, count in all_other_words.most_common(40):
                print(f"  {word!r:42s}  {count:5d}")
                for ex in all_examples[word][:2]:
                    print(f"      {ex!r}")


if __name__ == "__main__":
    main()
