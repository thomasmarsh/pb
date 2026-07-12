---
name: finish
description: Run the full verification gate (build/test/lint/typecheck across whichever of Haskell/Python/TypeScript changed) and deliver the mandatory end-of-session commit-message + seed-prompt blocks. Invoke this at the end of any session that changed code, before telling the user the work is done.
---

# Finishing a session

This skill exists because commit messages and full-suite verification are
easy to skip under time pressure, and skipping them is the single most
common source of user dissatisfaction across past sessions (see
`doc/plan/BACKLOG.md` history / root `CLAUDE.md`'s Commit Discipline
section). Do not report a task as "done" without completing every step below.

## 1. Run verification for every subsystem touched this session

Only run the suites for languages actually touched — but run ALL of them
for that language, not just the one file's tests:

```bash
# If compiler/ changed:
cd compiler && cabal build && cabal test --test-show-details=direct

# If cli/ changed:
cd cli && uv run ruff check && uv run pyright && uv run pytest lib/tests/ pipeline/tests/ api/tests/

# If ui/ changed:
cd ui && pnpm lint && pnpm typecheck && pnpm test && pnpm build
```

If a corpus-affecting compiler change was made, also run `./pb check-corpus`
and confirm the error count did not increase (baseline recorded in root
`CLAUDE.md`'s Quick Reference).

All of this must pass. An unexpected failure is a regression — stop and
read it before doing anything else. Do not report done with a failing gate.

## 2. Post-task grooming

Per root `CLAUDE.md`'s Session Scoping section: mark completed BACKLOG items
`[x]`, update `doc/plan/STRATEGY.md` and any referenced plan files with
current counts/status, and append any newly-discovered scope to BACKLOG.
List which docs you groomed (or state none needed grooming).

## 3. Deliver the two mandatory code blocks

This step is **never optional**, including when the only changes are to
gitignored files (`doc/plan/`, `BACKLOG.md`, `STRATEGY.md`). If there is no
source change to commit, say so explicitly in the first block rather than
omitting it silently — the user has been burned by silent omission before.

1. **Recommended commit message** (conventional-commit style, ≤72-char
   subject, optional body):

   ```
   feat(dw): implement block scanner + AST skeleton (DW-A1)

   Parse .srd files into DataWindowFile with typed band/control/table stubs.
   Corpus gate: 262 DW files return non-stub JSON.
   ```

   Or, if nothing is committable:

   ```
   No commit needed — this session only edited gitignored plan/BACKLOG files.
   ```

2. **Recommended next-session seed prompt** — self-contained: charter, which
   plan file to read, key counts/baselines, prerequisite check.

Do not run `git add` or `git commit` yourself — these are proposals only.
