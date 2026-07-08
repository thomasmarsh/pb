"""Privacy-safe check for fixed-width hard line-wrapping in a DDL dump.

Prints ONLY line-length statistics -- no content. Confirms or rules out
whether a DDL export was hard-wrapped at a fixed column width regardless of
token boundaries (e.g. a SQL*Plus SPOOL with LINESIZE set too small), which
would split keywords like ENABLE mid-word across a real newline
(`EN\\nABLE`) -- a failure no regex-based keyword stripping in ddl.py can
ever match, since it expects each keyword as one contiguous token.

Usage:
    python3 scripts/check_ddl_line_wrap.py /path/to/real_schema.sql
"""

from __future__ import annotations

import sys
from collections import Counter


def main() -> None:
    path = sys.argv[1]
    lengths: Counter[int] = Counter()
    with open(path, errors="replace") as f:
        for line in f:
            lengths[len(line.rstrip("\n"))] += 1

    total_lines = sum(lengths.values())
    max_len = max(lengths)
    print(f"total_lines={total_lines}")
    print(f"max_line_length={max_len}")
    print(f"lines_at_max_length={lengths[max_len]} ({lengths[max_len] / total_lines:.1%})")
    print("top 5 line lengths by frequency:")
    for length, n in lengths.most_common(5):
        print(f"  length={length}: {n} lines ({n / total_lines:.1%})")


if __name__ == "__main__":
    main()
