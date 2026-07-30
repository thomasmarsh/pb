# pb-compiler — Working Protocol

This file covers protocol common to every subsystem: session start, scoping,
the staged verification loop, evidence discipline, documentation style, and
commit discipline. Subsystem-specific rules — Haskell Prelude/module layout,
TypeScript/SolidJS UI architecture rules, Python backend specifics — live in
nested files that Claude Code loads automatically once a session reads or
edits files in that subtree:

- `compiler/AGENTS.md` — Haskell parser/compiler (Prelude rules, Megaparsec
  guidance, Module Placement, Corpus Coverage Checklist)
- `ui/AGENTS.md` — TypeScript/SolidJS explorer (the 5 UI architecture rules,
  runtime test pattern)
- `cli/AGENTS.md` — Python backend (SQL mock mode, SQL worker bridge)

Read the relevant nested file at Stage 0 of any session touching that
subtree, even if not explicitly instructed to.

Deeper design judgment calls — fixing a bug that reads from a shared
primitive, or deciding whether a structural gap justifies building the
principled fix now — live in "Principles" section at the end of this document`. Read it in full before Stage 1 whenever either applies.

## Quick Reference

```text
cd compiler && cabal build                          # compile library + executables
cd compiler && cabal build --enable-tests           # compile tests too
cd compiler && cabal test                           # run test suite
cd compiler && cabal test --test-show-details=direct # verbose output
./pb check-corpus                    # 0 errors / 1490 files = baseline
cd cli && uv run pytest lib/tests/ pipeline/tests/ api/tests/  # Python tests
cd cli && uv run ruff check     # Python lint
cd cli && uv run pyright        # Python type check (0 errors baseline)
cd ui && pnpm typecheck         # TypeScript type check (explorer)
cd ui && pnpm lint              # ESLint (explorer)
cd ui && pnpm test              # Explorer reducer tests (64 tests)
cd ui && pnpm build             # Build explorer TS → static/dist/
PB_SQL_MOCK=1 uv run --project cli pb explore  # Run explorer with mock SQL (no MySQL needed)
```

## Session Start (read this every session)

1. **Read `doc/plan/BACKLOG.md` first** — the authoritative work queue. The
   user sets priority; confirm the charter matches the top unfinished item.
   Do not start work from `git status` alone.
2. **Charter names a plan number** (e.g. "plan 111a") → read that plan file
   in `doc/plan/` before touching `git`, glob, or any source. Plan files are
   the source of truth for scope, prerequisites, and verify steps. They are
   gitignored, so `git status` will never show they were updated.
3. **`doc/plan/` is gitignored.** Grooming edits there are real work but
   never appear in a commit; the commit only carries code + tests.
4. **Read the nested `AGENTS.md`** for whichever subsystem the charter
   touches (`compiler/`, `ui/`, `cli/`).

**Continuing a prior session:** read the plan file's Status/close-out section
first, then `git status` for the on-disk delta. Don't trust the on-disk state
— run `cabal build && cabal test` to get ground truth before deciding whether
to continue or revert.

**This file and its nested siblings are the orientation layer, not a
signature index.** Use `rg` to find the relevant module and read it directly
— a hand-maintained signature list goes stale faster than it helps.

## Session Scoping

- **Charter first.** State a one-sentence charter before Stage 0: "This
  session delivers X. [Y is out of scope.]" Infer from user intent; ask if
  ambiguous. No work starts until the charter is written.
- **Scope is fixed for the session.** New problems surfacing mid-session →
  log to `doc/plan/BACKLOG.md`; don't expand scope without explicit approval.
- **New failure exposed by a fix:** same root cause → fix it now (in
  charter); different root cause → one-line `BACKLOG.md` entry, keep going.
- **Primary failures hide secondary ones.** Corpus error counts key on the
  first failing line per file. Fix the primary mode, rerun, then
  re-categorize remaining errors before drawing conclusions.
- **Stop condition:** charter goal met + Stage 4 passes → stop. Don't pick up
  the next visible problem.
- **Post-task grooming (mandatory, before the commit message):** mark
  completed BACKLOG items `[x]` with a date/note; update `STRATEGY.md`'s
  current-state metrics and status; update plan files referencing superseded
  counts/signatures/status; append any new scope found to BACKLOG — never
  discard it silently.
- **BACKLOG.md entries stay short — one wrapped-prose line, roughly under
  400 characters.** Full narration (bug root-causes, verification numbers,
  session-by-session history) belongs in that item's `doc/plan/NNN-*.md`
  plan file, cited inline as `(doc/plan/NNN-slug.md)` — create the plan file
  if one doesn't exist yet, rather than writing the narration into BACKLOG
  itself. `doc/plan/` is gitignored, so BACKLOG.md has no git history of its
  own; the plan file is the durable record, not this file. Never put prose
  in a markdown table cell, only use flat bullet list.

---

## The Staged Verification Loop

Scale gates to the size of the change. Trivial changes (typo, rename,
single-line fix) may auto-proceed. Non-trivial changes stop at Stage 1 and
optionally Stage 3.

### Stage 0 — Read First (always)

- Read every file that will be touched before proposing a change. Use `rg
-n`/`rg -l` to locate the relevant section first.
- Locate callers before modifying a function.
- Subsystem-specific diagnostics (corpus-error sampling, JSON wire-format
  rules, canonical `cabal` invocation, etc.) live in the nested
  `AGENTS.md` — read it before diagnosing a failure in that subsystem.
- **Confirm hypotheses with a narrow failing test before Stage 1.** A test
  that currently fails is worth more than a long analysis. Don't skip it.

### Stage 1 — Propose

A proposal must name:

- Function signatures being added or changed (with types)
- Test case names (not bodies) and which `testGroup` path they belong to
- Module placement for new code
- **Every file that will be touched, and why** — required for any change
  spanning more than one file or more than one layer (Haskell/Python/TS)

**Non-trivial changes: stop here and wait for review.**

### Stage 2 — Failing Tests

Write tests first with real assertions expressing correct behaviour — an
import error is not a valid red phase.

```text
cabal build --enable-tests   # must compile cleanly
cabal test                   # tests must appear and fail, not error/crash
```

Same pattern for `pnpm`/`pytest`. Don't proceed until tests fail for the
right reason.

`assertFailure "unimplemented: <reason>"` is only for a temporary production
stub when the unit under test doesn't exist yet. Replace it with a real
assertion before Stage 3.

### Stage 3 — Implementation

```text
cabal build   # must be warning-free; -Wall is set; warnings are blockers
```

**Non-trivial changes: stop here and confirm before running the test suite.**

### Stage 4 — Verify

```text
cabal test --test-show-details=direct
cd cli && uv run ruff check && uv run pyright && uv run pytest lib/tests/ pipeline/tests/ api/tests/
cd ui && pnpm lint && pnpm typecheck && pnpm test
```

This full sweep — build, tests, lint, typecheck — is mandatory before
reporting a task done, not just the suite for the file you touched. An
unexpected failure is a regression — read it before changing anything. The
`/finish` skill runs this checklist plus the mandatory commit-message step;
invoke it at the end of any session that changed code.

---

## Evidence-Based Triangulation

**No speculative changes.** A change motivated by "might fix" rather than a
compiler error or a failing test needs explicit justification in Stage 1.

Evidence hierarchy, highest confidence first:

1. GHC compiler error with a stack trace
2. Failing test with an assertion message
3. `rg` result showing actual usage
4. Reading the file that contains the relevant code

## Analysis & Recommendations

Applies to architecture evaluations, migration calls, plan grounding, and
any "should we do X" judgment — not just implementation work.

- **Verdict first.** Lead with a clear judgment (good/bad,
  recommend/don't) in sentence one, then justify with evidence. Don't leave
  the judgment implicit for the user to derive.
- **No effort-based rejection without validation.** "Seems like a lot of
  work" isn't evidence unless the scope was actually measured (file/line
  count, a trial `rg`, a spike) — rank it below everything in the hierarchy
  above.
- **Ground comparative claims in real diffs.** Before calling two
  implementations/outputs "divergent" or "equivalent," run both and cite
  the actual diff — don't assert it from reading code alone.

## Change Scope

- **Prefer additive changes.** Don't delete a legacy endpoint, table, or
  code path unless explicitly instructed — add the new path alongside the
  old one and let the user retire it.
- **Multi-file changes require Stage 1 review** (see above) — non-negotiable
  for anything touching more than one file or more than one layer.

## Documentation & Comments

Applies to `doc/*.md`, architecture docs, plan files, this file, and — in
the stricter form below — source comments.

- **Present-state only.** Describe what the system currently does, not
  "used to"/"no longer"/"previously". Genuine history goes in a dedicated
  History subsection, not woven into current-state prose.
- **No negative framing for unsupported capability.** Describe what a
  feature does, not what it doesn't or used to.
- **Spell out plan/phase relationships** ("supersedes", "replaces") in a
  sentence rather than a one-word label that forces a clarifying round-trip.

**Source comments** (Haskell/Python/TypeScript, docstrings, `-- |` blocks)
must read as clean and self-standing to someone with zero memory of how the
code got there:

- **No work-log content.** Plan numbers, phase names, session dates,
  "Stage N", "replaces the old X" belong in `doc/plan/`, the session
  charter, or the commit message — not in source.
- **Comment only non-obvious WHY** — a hidden invariant, a workaround for a
  specific bug, a subtle correctness reason. If it only narrates what the
  code does or how it got that way, delete it.
- **Test:** would a reader five years from now need to dig up a deleted
  planning doc to parse this comment? If yes, rewrite it.

## Testing Discipline

Stage 4's full-suite sweep is mandatory before reporting done — not just the
tests for the file touched. Subsystem test structure (Haskell
`testGroup`/HUnit/Hedgehog, TypeScript `TestStore`/mock-env patterns) lives
in the nested `AGENTS.md` files.

- **Table-driven tests.** 3+ cases sharing an assertion shape → a table +
  loop/helper (`mapM_` in Haskell, `test.each`/a loop in pytest or vitest),
  not repeated structure.
- **No external snapshot files.** Inline expected values in assertions,
  using a local multi-line string constant for expected output.

---

## Token Efficiency

- **Prefer SEARCH/REPLACE over full rewrites.** Use Edit rather than
  rewriting whole files. Only rewrite when the diff would be larger than
  the file.
- **Use `rg` before reading.** `rg -l` to find which file, `rg -n` to find
  the line. Note: ripgrep has no `--include` option.
- **Budget every tool call.** Before any call, ask: "does this directly
  produce the deliverable?" If not, skip it.
- **Explore agents: max 1 per session.** Prefer reading 2–3 key files
  directly with `offset`+`limit` over broad exploration sweeps.
- **Never re-read files agents have summarized.** Trust agent output for
  planning; only read files directly when you need exact line numbers.
- **Use `offset`+`limit` on every Read.** Never read a full 300+ line file
  when you need one function.
- **Exact paths or instructions from the user → execute immediately.** No
  verification, no Glob, no "let me check" — especially if told not to.
- **Parallel edits: verify paths first.** One bad path fails the whole
  batch.
- **Research stop condition:** >10% of budget spent on research with no
  deliverable output yet → stop researching, start writing.

---

## Commit Discipline

**Never run `git add` or `git commit`.** At the end of every session that
touched any files — including gitignored-only sessions — after grooming,
output two blocks. Never optional, never silently skipped: if there is
nothing to commit, say so explicitly in block 1.

1. **Commit message** — conventional-commit style, subject ≤72 chars,
   optional body for multi-file changes:

```
feat(dw): implement block scanner + AST skeleton (DW-A1)

Parse .srd files into DataWindowFile with typed band/control/table stubs.
Corpus gate: 262 DW files return non-stub JSON.
```

or:

```
No commit needed — this session only edited gitignored plan/BACKLOG files.
```

1. **Next-session seed prompt** — a self-contained paragraph: charter, plan
   file to read, key counts/baselines, prerequisite check:

```
Charter: DW-A2 — implement typed `table(...)` parsing per doc/plan/21-dw-a2.md.
Prerequisite: DW-A1 complete and `cabal test` passing (619 tests).
Baseline: 262 DW files non-stub; ExRaw ≤ 1; BsRaw other ≤ 18.
Start at Stage 0: read doc/plan/21-dw-a2.md in full, then read
PB.AST.DataWindow and PB.Grammar.DataWindow to locate the stub functions
that need replacing.
```

These are proposals only — the user decides when and whether to commit. The
`/finish` skill runs Stage 4 verification and this commit-message step
together.

**Other commit rules (when the user does commit):**

- One commit per stage (or per logical unit within a stage)
- Message states what changed and why, not how
- Never commit with a warning-dirty `cabal build`
- Stage 2 failing-test stubs may be committed, marked with
  `assertFailure "unimplemented: ..."`
- Before committing parser changes: `./pb check-corpus` — error count must
  not increase (baseline: 0 errors / 1490 files)
- New failure categories found this session go in `BACKLOG.md` before
  committing

## Design Principles

Deeper judgment calls that don't fit the per-session operational loop in
`AGENTS.md`. Read this before Stage 1 whenever a fix touches a shared
primitive, or a structural/correctness gap might justify building the
principled fix now rather than deferring it.

### Primitive vs. Symptom Fixes

Applies whenever a fix reads from or derives from another module's computed
structure — an analysis pass on a shared `ProcFlow`/CFG, a UI reducer on an
API response, a materializer on a Datalog relation.

- **Find the primitive before fixing.** Identify which module actually
  produces the wrong value, then `rg` for every other consumer of it. A fix
  that only changes the output where the bug was observed — while the
  primitive still produces the same wrong value elsewhere — is a symptom
  fix, not a root fix.
- **State it in Stage 1.** Name the primitive, name the other known
  consumers, and say explicitly whether the fix lands in the primitive or
  the consumer, and why. If a consumer re-derives policy the primitive
  already half-encodes (a kill/use rule, a validation rule, a formatting
  rule), move that policy into the primitive as data/fields rather than
  re-implementing it locally.
- **Corpus-discovered bugs need this check especially.** The fastest fix is
  almost always at the consumer, not the source — that's the trap.
- **A missed shared-primitive gap caught later is a process gap.** Log why
  Stage 1 missed it in `doc/plan/BACKLOG.md`, not just the fix itself.

### Foundational Correctness Overrides Premature-Abstraction Caution

pb-compiler is under active foundational development — the AST/identifier
representation, analysis primitives, and Datalog rule substrate are still
being deliberately converged on, not stable systems being incrementally
patched. In that mode, avoiding rework outweighs the marginal cost of
building a structural fix correctly the first time.

- **Confirmed, currently-existing gap → build the principled fix now**,
  even for one caller. "Only one consumer" / "small measured payoff" /
  "three similar lines is fine" don't apply to a type, primitive, or
  invariant the codebase is already converging toward elsewhere — that
  reasoning is reserved for accidental/incidental duplication (a helper two
  call sites happen to share), not for this category.
- **Does not license speculative engineering.** Config knobs for imagined
  future requirements, unrequested extensibility layers, and abstracting
  over behavior that doesn't exist yet are still out of bounds. The trigger
  is a gap grounded the same way Evidence-Based Triangulation requires (a
  compiler error, a failing test, an `rg` result) — not "might matter
  someday."
- **How to apply.** If the objection to a fix is "not needed today, only
  one caller" and the fix is genuinely a type/primitive/invariant
  correction (not new behavior), that objection doesn't hold — propose
  building it in the Stage 1 proposal. This changes _whether_ to build the
  structural version, not _whether_ it needs Stage 0/1 discipline — an
  architecturally large fix still gets scoped as its own plan.
- **Reference case:** `PB.AST.Ident` — see `compiler/AGENTS.md`'s
  "Identifier typing is a standing goal" rule — and
  `doc/plan/170-datalog-discipline.md`'s three-question placement test
  apply this posture to two different axes: how identifiers are typed, and
  where logic lives.
