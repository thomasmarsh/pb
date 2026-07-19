# pb-compiler — Working Protocol

This file covers protocol common to every subsystem: session start, scoping,
the staged verification loop, evidence discipline, documentation style,
change scope, and commit discipline. Subsystem-specific rules — Haskell
Prelude/module layout, TypeScript/SolidJS UI architecture rules,
Python backend specifics — live in nested files that Claude Code loads
automatically once a session reads or edits files in that subtree:

- `compiler/CLAUDE.md` — Haskell parser/compiler (Prelude rules, Megaparsec
  guidance, Module Placement, Corpus Coverage Checklist)
- `ui/CLAUDE.md` — TypeScript/SolidJS explorer (the 5 UI architecture rules,
  runtime test pattern)
- `cli/CLAUDE.md` — Python backend (SQL mock mode, SQL worker bridge)

Read the relevant nested file at Stage 0 of any session touching that
subtree, even if not explicitly instructed to.

## Quick Reference

```text
cd compiler && cabal build                          # compile library + executables
cd compiler && cabal build --enable-tests           # compile tests too
cd compiler && cabal test                           # run test suite
cd compiler && cabal test --test-show-details=direct # verbose output
./pb check-corpus                    # 0 errors / 1053 files = baseline
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
   user sets priority; confirm the charter matches the top unfinished item. Do
   not start work from `git status` alone.
2. **If the charter references a plan number** (e.g. "plan 111a"), read that
   plan file in `doc/plan/` _before_ touching `git`, glob, or any source. Plan
   files are the source of truth for scope, prerequisites, and the exact
   verify steps. They are gitignored (see below), so `git status` will never
   tell you they were updated.
3. **`doc/plan/` is gitignored.** Plan files, BACKLOG, and STRATEGY are _not_
   committed — they live only on disk. Grooming edits to them are real work
   but will never appear in a commit; the commit only carries code + tests.
4. **Read the nested `CLAUDE.md` for whichever subsystem the charter touches**
   (`compiler/`, `ui/`, `cli/`) — see the pointer list at the top of this file.

**Interrupted-session recovery.** When asked to "continue" a prior session,
locate the plan file and read its "Status" / close-out section first — it
records what landed and what remains. Then check `git status` to see the
on-disk delta. Do not assume the on-disk state is correct: an interrupted
session may have left code that doesn't compile or tests that fail for the
wrong reason. Run `cabal build && cabal test` early to get ground truth before
deciding whether to continue or revert. (The 111a session left a test file
using `head`, which `PB.Prelude` hides — the plan file had the full picture,
but reading `git status` first wasted a step.)

**This file and its nested `CLAUDE.md` siblings are the orientation layer.**
Module signatures are not mirrored here — use `rg` to locate the relevant
module and read it directly (see Token Efficiency below); at this codebase's
size a hand-maintained signature index goes stale faster than it can be kept
current, and a stale entry is worse than no entry.

## Session Scoping

**Charter first.** Before Stage 0, state a one-sentence charter:

> "This session delivers X. [Y is out of scope.]"

Infer the charter from the user's intent. If ambiguous, ask before reading any code. No work starts until the charter is written.

**Scope is fixed for the session.** If new problems surface mid-session, log them to `doc/plan/BACKLOG.md` — do not expand the current session's scope without explicit user approval.

**Classifying new failures.** When a fix exposes additional failures:

- Same root cause as the current fix → fix it in this session (it is within charter)
- Different root cause → one-line entry in `doc/plan/BACKLOG.md`; continue with the current charter

**Primary failures hide secondary failures.** Corpus error counts are keyed on the _first_ failing line per file. A dominant failure mode can mask other bugs in the same file. Fix the primary mode, rerun the corpus check, then re-categorize the remaining errors before drawing conclusions.

**Stop condition.** Charter goal met + full verification (see Stage 4) passes → stop. Do not pick up the next visible problem.

**Post-task grooming.** After the stop condition is met, before proposing the commit message, update planning artifacts to reflect new understanding:

- Mark completed BACKLOG items `[x]` with a short completion note and date.
- Update `doc/plan/STRATEGY.md`: current-state metrics, track status, recommended session order.
- Update any plan files (e.g. `doc/plan/20-dw-a1.md`) that reference superseded counts, signatures, or status.
- If the session revealed new scope, append to BACKLOG — do not silently discard the finding.

This grooming step is mandatory; do not skip it to save time.

**`doc/plan/BACKLOG.md`** is the authoritative work queue. The user sets priority order. The assistant only appends — never reorders. Read it at session start to confirm the charter matches the top unfinished item.

---

## The Staged Verification Loop

Scale gates to the size of the change. Trivial changes (typo, rename, single-line fix) may auto-proceed. Non-trivial changes stop at Stage 1 and optionally Stage 3.

### Stage 0 — Read First (always)

Before proposing any change, read every file that will be touched. Use `rg` to locate the relevant section before reading the full file:

```text
rg -n "functionName" compiler/src/
rg -l "LogicalLine" compiler/src/
```

No change is proposed without a prior read of all relevant modules. Locate callers before modifying a function.

**Subsystem-specific Stage 0 diagnostics live in the nested `CLAUDE.md` files** — e.g. `compiler/CLAUDE.md` covers corpus-error sampling, the JSON wire-format encoding rules, and the canonical `cabal` invocation. Read the relevant one before diagnosing a failure in that subsystem.

**Confirm hypotheses with a narrow test before Stage 1.** After reading code and forming a theory, write a one-line `testCase` (or the language-appropriate equivalent) that asserts the correct output and run it. A test that currently fails is worth more than a long analysis. Do not skip this step.

### Stage 1 — Propose

A proposal must name:

- Function signatures being added or changed (with types)
- Test case names (not bodies) and which `testGroup` path they belong to
- Module placement for new code
- **Every file that will be touched, and why** — required for any change spanning more than one file or more than one layer (Haskell/Python/TS)

**Non-trivial changes: stop here and wait for review.**

### Stage 2 — Failing Tests

Write tests first with real assertions expressing the correct behaviour. The tests must fail because the production code is wrong — not because the test itself is a placeholder. An import error is not a valid red phase for a TDD test. Verify:

```text
cabal build --enable-tests   # must compile cleanly
cabal test                   # tests must appear and fail, not error/crash
```

Similar for pnpm and pytest.

Do not proceed until tests are failing for the right reason.

Use `assertFailure "unimplemented: <reason>"` only when the unit under test does not exist yet and you need a temporary stub in the production code to keep the project compiling. Once the production stub exists, replace the `assertFailure` with a real assertion before Stage 3.

### Stage 3 — Implementation

Write the code. Before proceeding:

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

All tests must pass. An unexpected failure is a regression — read it before changing anything. **This full sweep — build, tests, lint, typecheck — is mandatory before reporting a task done, not just the suite for the file you touched.** The `/finish` skill (`.claude/skills/finish/SKILL.md`) runs this checklist plus the mandatory commit-message step below; invoke it at the end of any session that changed code.

---

## Evidence-Based Triangulation

**No speculative changes.** A change motivated by "might fix" or "should help" rather than a compiler error or a failing test requires explicit justification in the Stage 1 proposal.

Evidence hierarchy (highest to lowest confidence):

1. GHC compiler error with a stack trace
2. Failing test with an assertion message
3. `rg` result showing actual usage
4. Reading the file that contains the relevant code

---

## Analysis & Recommendations

Applies to architectural evaluations, migration recommendations, plan grounding, and any "should we do X" judgment call — not just implementation work.

- **Verdict first.** Lead with a clear qualitative judgment (good/bad, recommend/don't-recommend, migrate/don't-migrate) in the first sentence, then justify it with evidence from the actual source. Do not describe only the mechanism and leave the judgment implicit — the user has to make a decision from the answer, not derive one.
- **No effort-based rejection without validation.** Do not recommend against an approach because it "seems like a lot of work" or "would require significant refactoring" unless the scope has actually been measured against the real codebase (file count, line count, a trial `rg`, a spike). An unvalidated effort estimate is not evidence — rank it below everything in the Evidence-Based Triangulation hierarchy above.
- **Ground comparative claims in real diffs.** Before asserting that two implementations, two engine outputs, or two derivations "disagree" or "diverge" (or agree), actually run both and diff the output, then cite the concrete diff. Do not assert divergence from reading code alone.

## Change Scope

- **Prefer additive changes.** Do not delete a legacy endpoint, table, or code path unless the user explicitly instructs it. Add the new path alongside the old one; let the user decide when/whether to retire the old one.
- **Confirm scope before multi-file changes.** Stage 1 above already requires this ("stop here and wait for review," and the file list is now a required part of the proposal) — treat it as non-negotiable for anything touching more than one file or more than one layer.

## Documentation Style

Applies to `doc/*.md`, architecture docs, plan files, and this file itself.

- **Present-state only.** Describe what the system currently does. Do not add historical or narrative framing — no "used to", "no longer", "previously", "only X is available now". If history genuinely matters (a plan's changelog, a design-decision rationale), put it in a dedicated "History" subsection — don't weave it into the prose describing current behavior.
- **No negative framing for removed or unsupported capability.** Don't describe a feature by what it isn't or doesn't do relative to some prior state ("no jsonl support" reads as a complaint about a gap). Describe what it does support, full stop.
- **State plan/phase relationships precisely.** Words like "supersedes," "replaces," or "extends" are ambiguous without a sentence of explanation — spell out the actual relationship rather than reaching for a one-word label that forces a clarifying round-trip.

## Code Comments

Source-code comments (Haskell/Python/TypeScript, docstrings, `-- |` Haddock blocks) are held to a stricter version of Documentation Style, not a looser one — the "code comment tied to a specific decision" carve-out that used to live in Documentation Style is gone. Code must read as clean and self-standing to someone with zero memory of how it got there.

- **No work-log content in code.** Plan numbers, phase names, session dates, "Stage N", ticket references, and sentences like "this used to be a SQL view", "replaces the old X", "Plan 175 Phase 2 migrated this" do not belong in source comments — they belong in `doc/plan/` files, the session charter, or the commit message. A future reader of the code should not need to know a migration happened at all.
- **Describe current behavior and non-obvious WHY only.** A comment earns its place by explaining something the code itself can't: a hidden invariant, a workaround for a specific bug, a subtle correctness reason for an otherwise-surprising choice. If the comment is only narrating what the code does, or narrating how the code came to be this way, delete it.
- **A grounding fact may stay if it's load-bearing WHY, stripped of narrative.** "An unfiltered `proc` relation inflates `proc_dead` with every builtin stub method" is a reason to keep the filter — keep it. "A real openpay `--db` run in session N caught this" is a work-log detail — cut it.
- **Test this by imagining the comment five years from now.** If a plan number or "used to" phrase would force a future reader to go dig up a deleted planning doc just to understand a comment in currently-live code, rewrite it.

## Primitive vs. Symptom Fixes

Applies whenever the code being fixed reads from or derives its data from
another module's computed structure — an analysis pass built on a shared
`ProcFlow`/CFG, a UI reducer built on an API response, a materializer built
on a Datalog relation.

- **Find the primitive before writing the fix.** Identify which module
  actually produces the wrong value, and `rg` for every other consumer of
  that primitive. A fix that only changes the output where the bug was
  observed, while the primitive itself still produces the same wrong value
  for other callers, is incomplete — it patched a symptom, not the cause.
- **State it in the Stage 1 proposal.** Name the primitive, name the other
  known consumers, and say explicitly whether the fix lands in the
  primitive or the consumer, and why. If a consumer re-derives policy the
  primitive already half-encodes (a kill/use rule, a validation rule, a
  formatting rule), prefer moving that policy into the primitive and
  exposing it as data/fields, not recomputing it locally — a second
  implementation of the same policy is where these bugs hide.
- **Corpus/production-discovered bugs need this check especially.** Stage
  0's narrow-test requirement targets unit-level bugs; a bug found via
  real-corpus spot-checking additionally needs a "where does this data
  actually come from" pass before the fix is written — the fastest fix is
  almost always at the consumer, not the source, and that's the trap.
- **A later architecture review catching this is a process gap, not just a
  bug.** If Stage 1 should have caught a shared-primitive gap and didn't,
  log why in `doc/plan/BACKLOG.md`'s finding, not only the fix itself.

## Foundational Correctness Overrides Premature-Abstraction Caution

This project overrides the general "don't add abstractions beyond what the
task requires" default for one specific case. pb-compiler is under active
foundational development — the AST/identifier representation, analysis
primitives, and Datalog rule substrate are all still being deliberately
converged on, not stable systems being incrementally patched. In that mode,
avoiding rework outweighs the marginal cost of building a structural fix
correctly the first time.

- **When a real, currently-existing structural or correctness gap is
  confirmed** — not hypothetical — build the principled fix now, even if
  only one caller needs it today. "Only one consumer," "small measured
  payoff," and "three similar lines is fine" are not valid reasons to defer
  it. That reasoning is for accidental/incidental duplication (a helper
  function two call sites happen to share), not for a type, primitive, or
  invariant the codebase is already converging toward everywhere else.
- **This does not license speculative engineering.** Config knobs for
  imagined future requirements, extensibility layers nobody has requested,
  and abstracting over behavior that doesn't exist in the codebase yet are
  still out of bounds — that half of the general default still applies. The
  trigger is a gap that is real and present today, grounded the same way
  Evidence-Based Triangulation requires (a compiler error, a failing test,
  an `rg` result showing the actual current shape) — not "this might matter
  someday."
- **Worked example:** `doc/plan/178-canonical-identifier.md`/`179-
canonical-identifier-consumers.md` — `PB.AST.Ident` was minted for every
  PB-identifier AST field regardless of how many consumers currently read
  a given one; see `compiler/CLAUDE.md`'s "Identifier typing is a standing
  goal" rule for the concrete instance. `doc/plan/170-datalog-discipline.md`'s
  three-question placement test is the same posture applied to a different
  axis (where logic lives, not how identifiers are typed).
- **How to apply:** if the argument against a fix is "not needed today
  since only one caller uses it" and the fix is genuinely a type/primitive/
  invariant correction (not new behavior or a new feature), that argument
  does not hold here — propose building it, and say so plainly in the
  Stage 1 proposal rather than deferring to BACKLOG on cost/benefit
  grounds. This changes _whether_ to build the structural version, not
  _whether_ it still needs Stage 0/Stage 1 discipline — an architecturally
  large fix still gets scoped as its own plan, same as anything else.

## Testing Discipline

Full-suite verification (Stage 4 above) is mandatory before reporting any task done — not just the tests for the file touched. Subsystem-specific test structure (Haskell `testGroup`/HUnit/Hedgehog, TypeScript `TestStore`/mock-env patterns) lives in the nested `CLAUDE.md` files.

**Table-driven tests.** When 3+ test cases share the same assertion shape, use a table + loop/helper instead of repeating identical structure (`mapM_` over a list in Haskell, `test.each`/a loop in pytest or vitest).

**No external snapshot files.** Inline expected values in assertions. Use a locally-defined multi-line string constant for expected output. Longer term we may loosen this requirement. Make a recommendation if unsure.

---

## Token Efficiency

**Prefer SEARCH/REPLACE over full rewrites.** Use the Edit tool rather than rewriting whole files. Only rewrite when the diff would be larger than the file.

**Use `rg` before reading.** Locate the relevant lines before opening a file. `rg -l` to find which file, `rg -n` to find the line. NOTE: ripgrep does _not_ have a `--include` option.

**Budget every tool call.** Each Read of a 300-line file costs real context budget. Before any tool call, ask: "does this directly produce the deliverable?" If not, skip it.

**Explore agents: max 1 per session.** Prefer reading 2–3 key files directly with `offset`+`limit` over launching broad exploration sweeps. Explore agents return large summaries — three parallel agents is a non-starter.

**Never re-read files agents have summarized.** Trust agent output for planning. Only read files directly when you need exact line numbers for edits, and even then use `offset`+`limit` to read only the relevant section.

**Use `offset`+`limit` on every Read.** Read only the lines you need — typically the first 50–100 lines for type declarations, or a specific line range from `rg -n` output. Never read a full 300+ line file when you need one function.

**When the user gives exact paths or instructions, execute immediately.** No verification, no Glob, no "let me check." Especially when the user explicitly says not to verify.

**Parallel edits: verify paths first.** A single bad path in a batch of parallel edits causes the entire batch to fail. Verify all paths exist before launching the batch.

**Stop condition for research:** If you've spent >10% of budget on research/exploration and haven't produced any deliverable output, STOP researching and start writing. You can always fill in gaps from the document itself.

---

## Commit Discipline

**Do not run `git add` or `git commit`.** At the end of every session that touched any files — including a session that only touched gitignored plan/BACKLOG files — after post-task grooming is complete, output two code blocks. This step is never optional and never silently skipped: if there is genuinely nothing to commit, say so explicitly in block 1 rather than omitting it.

1. **Recommended commit message** — follows conventional-commit style; one subject line (≤72 chars) describing what changed and why; an optional blank-line body for multi-file changes.

```
feat(dw): implement block scanner + AST skeleton (DW-A1)

Parse .srd files into DataWindowFile with typed band/control/table stubs.
Corpus gate: 262 DW files return non-stub JSON.
```

Or, if there is nothing committable this session (e.g. only gitignored plan-file grooming):

```
No commit needed — this session only edited gitignored plan/BACKLOG files.
```

1. **Recommended next-session seed prompt** — a self-contained paragraph the user can paste to start the next session. Include: charter, which plan file to read, key counts/baselines, and any prerequisite check.

```
Charter: DW-A2 — implement typed `table(...)` parsing per doc/plan/21-dw-a2.md.
Prerequisite: DW-A1 complete and `cabal test` passing (619 tests).
Baseline: 262 DW files non-stub; ExRaw ≤ 1; BsRaw other ≤ 18.
Start at Stage 0: read doc/plan/21-dw-a2.md in full, then read
PB.AST.DataWindow and PB.Grammar.DataWindow to locate the stub functions
that need replacing.
```

These are proposals only — the user decides when and whether to commit. Consider invoking the `/finish` skill (`.claude/skills/finish/SKILL.md`) to run the full Stage 4 verification and this commit-message step together, consistently.

**Other commit rules (when the user does commit):**

- One commit per stage (or per logical unit within a stage)
- Commit message: what changed and why, not how
- Do not commit with a warning-dirty `cabal build`
- Failing test stubs (Stage 2) may be committed; mark them clearly with `assertFailure "unimplemented: ..."`
- Before committing parser changes: `./pb check-corpus`
  The error count must not increase. Baseline: 0 errors / 1053 files.
- Any new failure categories found during a session must be recorded in `doc/plan/BACKLOG.md` before committing.
