#!/usr/bin/env python3
"""Plan 162 Phase 0b — redacted PL/SQL grammar coverage report.

Standalone, offline, single-file-tree-in / aggregate-report-out. Walks a
directory of Oracle PL/SQL source files, attempts to parse each one with the
ANTLR4 grammars-v4/sql/plsql grammar (Python target, vendored in
./generated/), and prints a SHORT AGGREGATE REPORT to stdout.

PRIVACY CONTRACT (do not modify without re-reading doc/plan/162-plsql-python-
frontend.md's "Corpus access constraint" section first):

  - This script NEVER prints, logs, or writes source text, identifiers,
    table/column names, or file paths from the scanned corpus.
  - Failure categories are keyed by structural info only: the innermost
    ANTLR parser rule name, and the *type* (symbolic token name, e.g.
    IDENTIFIER, EQUALS_OP) of the offending/expected tokens -- never their
    text.
  - Unit-kind counts (PACKAGE/PROCEDURE/FUNCTION/TRIGGER/...) are keyword
    occurrence COUNTS only, never the matched object name.
  - The only output is the printed report. Nothing is written to disk,
    nothing is transmitted over a network -- this script makes no network
    calls at all.

Copy this whole directory (script + generated/ + requirements.txt) to the
machine with corpus access, install the one dependency, and run:

    pip install -r requirements.txt
    python3 plsql_coverage_report.py /path/to/plsql/corpus

Hand-type the printed report back -- it is short by design (a few dozen
lines), never a dump.
"""
import argparse
import re
import signal
import sys
import time
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent / "generated"))

from antlr4 import InputStream, CommonTokenStream  # noqa: E402
from antlr4.error.ErrorListener import ErrorListener  # noqa: E402

from PlSqlLexer import PlSqlLexer  # noqa: E402
from PlSqlParser import PlSqlParser  # noqa: E402

DEFAULT_EXTENSIONS = {".sql", ".pks", ".pkb", ".pkg", ".trg", ".prc", ".fnc", ".pls", ".plb"}

# Keyword-occurrence scan only -- deliberately does not capture the object
# name group, so no identifier is ever extracted from matched text.
UNIT_KIND_PATTERNS = {
    "PACKAGE BODY": re.compile(r"\bCREATE\s+(OR\s+REPLACE\s+)?PACKAGE\s+BODY\b", re.IGNORECASE),
    "PACKAGE": re.compile(r"\bCREATE\s+(OR\s+REPLACE\s+)?PACKAGE\b(?!\s+BODY)", re.IGNORECASE),
    "PROCEDURE": re.compile(r"\bCREATE\s+(OR\s+REPLACE\s+)?PROCEDURE\b", re.IGNORECASE),
    "FUNCTION": re.compile(r"\bCREATE\s+(OR\s+REPLACE\s+)?FUNCTION\b", re.IGNORECASE),
    "TRIGGER": re.compile(r"\bCREATE\s+(OR\s+REPLACE\s+)?TRIGGER\b", re.IGNORECASE),
    "TYPE BODY": re.compile(r"\bCREATE\s+(OR\s+REPLACE\s+)?TYPE\s+BODY\b", re.IGNORECASE),
    "TYPE": re.compile(r"\bCREATE\s+(OR\s+REPLACE\s+)?TYPE\b(?!\s+BODY)", re.IGNORECASE),
}


class TimeoutErrorLocal(Exception):
    pass


def _alarm_handler(signum, frame):
    raise TimeoutErrorLocal("per-file timeout")


class RedactedErrorListener(ErrorListener):
    """Captures structural error shape only -- never offending-token text."""

    def __init__(self, recognizer_vocab):
        super().__init__()
        self.errors = []
        self._vocab = recognizer_vocab

    def syntaxError(self, recognizer, offendingSymbol, line, column, msg, e):
        rule_stack = []
        try:
            ctx = recognizer._ctx
            while ctx is not None:
                rule_stack.append(recognizer.ruleNames[ctx.getRuleIndex()])
                ctx = ctx.parentCtx
        except Exception:
            pass

        offending_type = None
        if offendingSymbol is not None:
            offending_type = self._symbolic_name(offendingSymbol.type)

        expected_types = []
        if e is not None and hasattr(e, "getExpectedTokens"):
            try:
                interval_set = e.getExpectedTokens()
                for t in list(interval_set.toList())[:8]:  # cap, never dump the whole vocabulary
                    expected_types.append(self._symbolic_name(t))
            except Exception:
                pass

        self.errors.append({
            "innermost_rule": rule_stack[0] if rule_stack else None,
            "offending_type": offending_type,
            "expected_types": tuple(sorted(expected_types)),
        })

    def _symbolic_name(self, token_type):
        try:
            name = self._vocab.symbolicNames[token_type]
            return name if name else f"<type {token_type}>"
        except Exception:
            return f"<type {token_type}>"


def parse_file(text: str, timeout_sec: int):
    input_stream = InputStream(text)
    lexer = PlSqlLexer(input_stream)
    lexer.removeErrorListeners()
    lex_errs = RedactedErrorListener(lexer)
    lexer.addErrorListener(lex_errs)

    tokens = CommonTokenStream(lexer)
    parser = PlSqlParser(tokens)
    parser.removeErrorListeners()
    parse_errs = RedactedErrorListener(parser)
    parser.addErrorListener(parse_errs)

    signal.alarm(timeout_sec)
    try:
        parser.sql_script()
    finally:
        signal.alarm(0)

    return lex_errs.errors + parse_errs.errors


def collect_files(root: Path, exts: set):
    out = []
    for p in root.rglob("*"):
        if p.is_file() and p.suffix.lower() in exts:
            out.append(p)
    return sorted(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("corpus_dir", type=Path, help="Directory to scan (recursively)")
    ap.add_argument("--ext", nargs="*", default=None,
                     help=f"File extensions to scan (default: {sorted(DEFAULT_EXTENSIONS)})")
    ap.add_argument("--timeout", type=int, default=10, help="Per-file parse timeout in seconds (default: 10)")
    ap.add_argument("--top-n", type=int, default=15, help="Rows in the failure-category table (default: 15)")
    args = ap.parse_args()

    exts = set(e.lower() if e.startswith(".") else f".{e.lower()}" for e in args.ext) if args.ext else DEFAULT_EXTENSIONS

    if not args.corpus_dir.is_dir():
        print(f"error: {args.corpus_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    signal.signal(signal.SIGALRM, _alarm_handler)
    sys.setrecursionlimit(10000)

    files = collect_files(args.corpus_dir, exts)
    total_files = len(files)
    total_lines = 0
    unit_kind_counts = Counter()

    status_counts = Counter()
    fail_category_counts = Counter()
    error_count_buckets = Counter()  # "1", "2-5", "6+" errors per failing file -- isolability proxy

    t_start = time.time()

    for i, path in enumerate(files, 1):
        print(f"\r  scanning {i}/{total_files}...", end="", file=sys.stderr, flush=True)
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except Exception:
            status_counts["read_error"] += 1
            continue

        n_lines = text.count("\n") + 1
        total_lines += n_lines

        for kind, pattern in UNIT_KIND_PATTERNS.items():
            unit_kind_counts[kind] += len(pattern.findall(text))

        if not text.strip():
            status_counts["empty"] += 1
            continue

        try:
            errors = parse_file(text, args.timeout)
        except TimeoutErrorLocal:
            status_counts["timeout"] += 1
            continue
        except RecursionError:
            status_counts["crash_recursion"] += 1
            continue
        except Exception as e:
            status_counts[f"crash_{type(e).__name__}"] += 1
            continue

        if not errors:
            status_counts["pass"] += 1
        else:
            status_counts["fail"] += 1
            n_err = len(errors)
            bucket = "1" if n_err == 1 else ("2-5" if n_err <= 5 else "6+")
            error_count_buckets[bucket] += 1
            first = errors[0]
            fail_category_counts[(first["innermost_rule"], first["offending_type"], first["expected_types"])] += 1

    elapsed = time.time() - t_start
    print(file=sys.stderr)  # newline after progress carriage-returns

    # ---- Aggregate report (safe to hand-type back) ----
    print("=" * 70)
    print("Plan 162 Phase 0b — PL/SQL grammar coverage report (redacted)")
    print("=" * 70)
    print(f"\nScan wall time: {elapsed:.1f}s")
    print(f"Total files scanned: {total_files}")
    print(f"Total lines: {total_lines}")

    print("\nUnit-kind occurrence counts (keyword scan, count only):")
    for kind, count in sorted(unit_kind_counts.items(), key=lambda kv: -kv[1]):
        if count:
            print(f"  {kind:14s} {count}")

    print("\nParse outcome counts:")
    for status, count in status_counts.most_common():
        pct = 100 * count / total_files if total_files else 0
        print(f"  {status:16s} {count:5d}  ({pct:.1f}%)")

    n_fail = status_counts.get("fail", 0)
    if n_fail:
        print(f"\nFailing-file error-count distribution (isolability proxy, n={n_fail}):")
        for bucket in ("1", "2-5", "6+"):
            c = error_count_buckets.get(bucket, 0)
            print(f"  {bucket:6s} errors: {c}")

    print(f"\nTop {args.top_n} failure categories (innermost_rule, offending_token_type, expected_token_types):")
    for (rule, off_type, exp_types), count in fail_category_counts.most_common(args.top_n):
        exp_str = ",".join(exp_types) if exp_types else "-"
        print(f"  {count:4d}  rule={rule}  found={off_type}  expected=[{exp_str}]")

    print("\n" + "=" * 70)
    print("End of report. Nothing else was written or transmitted.")
    print("=" * 70)


if __name__ == "__main__":
    main()
