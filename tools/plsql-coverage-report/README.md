# PL/SQL grammar coverage report (Plan 162 Phase 0b)

Standalone, offline tool. Copy this whole directory to the machine that has
access to the real Oracle PL/SQL corpus, then:

```
python3 -m venv venv
venv/bin/pip install -r requirements.txt
venv/bin/python plsql_coverage_report.py /path/to/plsql/corpus
```

Optional flags:

- `--ext .sql .pkb ...` — override the scanned file extensions (default:
  `.sql .pks .pkb .pkg .trg .prc .fnc .pls .plb`).
- `--timeout N` — per-file parse timeout in seconds (default 10). A file
  that times out is counted, not retried or dumped.
- `--top-n N` — rows in the failure-category table (default 15).

## What this does NOT do

- No network calls, ever (nothing to disable — none exist in the code).
- No output file is written; the report goes to stdout only.
- Never logs source text, identifiers, table/column names, or file paths.

## What to send back

Copy the entire printed report (it's short — a few dozen lines) back into
the conversation, hand-typed. That's the only thing that needs to leave the
corpus environment.

## What's in this directory

- `plsql_coverage_report.py` — the report script.
- `generated/` — the ANTLR4 Python-target parser generated from the real
  `grammars-v4/sql/plsql` grammar (Phase 0a), with the one known ANTLR
  Python3-target codegen quirk already patched (see "Known codegen quirk"
  below). Nothing here is corpus-derived.
- `requirements.txt` — one dependency: `antlr4-python3-runtime==4.13.2`
  (must match the ANTLR version used to generate `generated/`, currently
  4.13.2). No other Python packages are used.

## Known codegen quirk (already patched in generated/)

The upstream grammar's semantic predicates are written using `this.` (e.g.
`this.isVersion12()`), which is valid in most ANTLR4 targets but not
Python3 — Python has no `this`. A raw `antlr4 -Dlanguage=Python3` codegen
run leaves this literal and every predicate call raises `NameError` at parse
time. `generated/PlSqlParser.py` and `generated/PlSqlLexer.py` in this
directory already have `this.` mechanically replaced with `self.` (42 and 2
occurrences respectively, all inside semantic-predicate calls where `self`
is the enclosing parser/lexer instance) — no need to redo this if
regenerating from a newer grammar revision, just reapply the same
substitution.
