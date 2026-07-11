# PL/SQL grammar coverage report (Plan 162 Phase 0b)

Standalone, offline tool. Copy this whole directory to the machine that has
access to the real Oracle PL/SQL corpus, then:

```
java -jar plsql-coverage-report.jar /path/to/plsql/corpus
```

That's it — no build step, no dependency installation. The jar is
self-contained (bundles the ANTLR Java runtime and the generated PL/SQL
parser) and requires only a JRE 8 or newer.

Optional flags:

- `--ext .sql .pkb ...` — override the scanned file extensions (default:
  `.sql .pks .pkb .pkg .trg .prc .fnc .pls .plb`).
- `--timeout N` — per-file parse timeout in seconds (default 60). A file
  that times out is counted, not retried or dumped.
- `--top-n N` — rows in the failure-category table (default 15).
- `--dewrap-width N` / `--dewrap-tolerance N` — tune the hard-wrap rejoin
  heuristic (see "Hard-wrap handling" below). Defaults: 80 / 0.
- `--no-dewrap` — disable the hard-wrap rejoin heuristic entirely.

## Why Java, not Python

The first version of this tool bridged to ANTLR's Python target. Measured
head-to-head on the same real-world files, the Java target parses **~15x
faster** (402.7s vs 26.9s for an identical 453-file/96,491-line corpus —
see `doc/plan/162-plsql-python-frontend.md`'s Status section for the full
comparison). With 763+ files in the real corpus, that difference is the gap
between a coffee-break wait and toughening through several stalled sessions
waiting on a report. Java also requires zero dependency installation on the
target machine (no `pip install`) — a JRE, which is normally already
present, is the only prerequisite.

## What this does NOT do

- No network calls, ever (nothing to disable — none exist in `src/CoverageReport.java`).
- No output file is written; the report goes to stdout only.
- Never logs source text, identifiers, table/column names, or file paths.

## What to send back

Copy the entire printed report (it's short — a few dozen lines) back into
the conversation, hand-typed. That's the only thing that needs to leave the
corpus environment.

## What's in this directory

- `plsql-coverage-report.jar` — the prebuilt, runnable, self-contained tool.
  This is what you actually run.
- `src/CoverageReport.java` — the driver source (dewrap heuristic, unit-kind
  scan, redacted error listener, CLI, report printing).
- `gen/*.java` — the ANTLR4 Java-target parser generated from the real
  `grammars-v4/sql/plsql` grammar. Nothing here is corpus-derived.
- `build.sh` — rebuilds `plsql-coverage-report.jar` from `src/` + `gen/`.
  **Not needed to use the tool** — only if you change `CoverageReport.java`
  or regenerate `gen/` from a newer grammar revision. Fetches the ANTLR
  Java runtime jar from Maven Central at build time (the only network
  access anywhere in this toolchain, and it never touches anything
  corpus-related).

## JDK 8 compatibility

The target environment has JDK 1.8, not a newer JDK. This matters in two
independent ways, both handled:

1. **The ANTLR 4.13.2 runtime's own class files** are compiled to class-file
   major version 52 (Java 8) — confirmed via `javap -verbose`. No issue.
2. **Our own compiled classes** (`gen/*.java` + `CoverageReport.java`) are
   built with `javac --release 8`, which both restricts language features
   to Java 8 and forces the output class-file version to match — verified
   the same way. `build.sh` always passes `--release 8`; if you rebuild by
   hand, do the same or the jar will fail to load on the target JRE with
   `UnsupportedClassVersionError`.

## Hard-wrap handling

Real Oracle DDL dumps hard-wrap every physical line at exactly column 80
with a bare newline — including mid-identifier, e.g. a line ending
`...PROCEDURE_NA` immediately followed by a line starting `ME IS...`. Left
alone this poisons the report with spurious parse failures unrelated to
actual grammar coverage.

`dewrapHardWrappedLines()` in `CoverageReport.java` rejoins a line boundary
only when (1) the line is exactly `--dewrap-width` (default 80) characters
and (2) the character on each side of the break is a PL/SQL
identifier-continuation character (`[A-Za-z0-9_$#]`). Real PL/SQL
formatting never places a raw newline inside a token, so (2) alone is a
strong, low-false-positive signal; (1) corroborates it against the reported
wrap width. On by default. The report prints a `Hard-wrap rejoins
performed: N (in M files)` line — a count, safe under the redaction
contract.

## Known ANTLR pitfall this tool works around (fixed in `src/`, not `gen/`)

`RecognitionException.getExpectedTokens()` assumes a parser rule-invocation
context. On a **lexer-level** error (e.g. a stray `$` the lexer can't match
to any token — seen in real files using `$IF`/conditional-compilation-style
syntax) that context doesn't exist, and calling it throws
`IllegalArgumentException: Invalid state number` from deep inside the ANTLR
runtime. `CoverageReport.java`'s error listener wraps that call in its own
try/catch (see the comment at the call site) so a lexer-level error is
correctly counted as a parse failure with no expected-token detail, not a
tool crash. Found and fixed during this tool's own development by running
the full public corpus and checking a `crash` status did not appear where
the Python-target tool (which had the equivalent guard from the start) had
none.
