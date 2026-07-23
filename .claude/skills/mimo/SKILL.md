---
name: mimo
description: How to delegate work to the mimo CLI agent effectively. Load this BEFORE running any `mimo run` command, and before writing any spec file intended for mimo to execute. Applies whenever the task involves invoking mimo, mimocode, or delegating mechanical/token-heavy execution work to an external coding agent from within a Claude Code session.
---

# Working with mimo

`mimo` (mimocode) is a separate, fast CLI coding agent with effectively
unlimited token budget, invoked as a subprocess via `mimo run`. It is
useful for absorbing token-heavy, mechanical, well-specified execution
work — but it is not a substitute for judgment. This skill exists because
we learned its failure modes the hard way (Plan 166 Stages 3-6, 2026-07-11)
and should keep grooming it as more is learned. Update this file whenever
a new mimo failure mode or a better invocation pattern is discovered —
don't let the lesson live only in that session's transcript.

## The one rule everything else follows

**Verify first, delegate second.** Before writing a task for mimo, you
(Claude) must already be able to state the exact expected output or
behavior. If you can't — if there's a genuine open design or semantic
question — that question is not ready to hand to mimo. Resolve it
yourself first (read code, reason it through, and for anything
non-obvious in an external tool's actual behavior — a query language, a
CLI flag, a library function — write the smallest possible standalone
test and *run it* directly, rather than reasoning from memory or docs
alone). Only once you can write down the exact correct answer does the
remaining work become "apply this exact thing and verify it," which is
what mimo is actually good at.

Concretely, in one real session: an under-verified Souffle/Datalog design
handed to mimo produced a multi-round flailing loop, a legitimate but
unplanned engine change, and ultimately had to be finished by Claude
directly anyway — netting out roughly break-even on effort. A
pre-verified design (confirmed against the real `souffle` CLI on a tiny
fixture first) handed to mimo as an unambiguous, narrow task landed
cleanly in one pass. Same tool, same kind of task — the difference was
entirely whether the hard thinking happened before or during delegation.

## Scoping: one narrow task per invocation, zero exposure to future stages

mimo does not reliably honor "stop here, don't do the next thing"
instructions if the next thing is visible anywhere in its context. This
was observed directly: given a single combined document describing
stages 3 through 6 with an explicit "do Stage 3 only, then stop," it did
in fact stop correctly — but this is a probabilistic outcome, not a
guarantee, and is not something to rely on for anything with real
consequences (a shared branch, a build that others depend on).

- Extract *only* the current stage/task into its own standalone spec
  file. Do not attach or reference a multi-stage document, even with a
  "your job is only section N" instruction inside it.
- If a task is naturally large, break it into the smallest pieces that
  are each independently verifiable (build + test + whatever the
  task-specific correctness gate is), and run them as separate `mimo run`
  invocations.
- Between invocations, verify the diff yourself (at least skim `git diff
  --stat` and the touched files) before deciding whether to proceed —
  don't chain further stages automatically just because mimo's own report
  says it succeeded and offers to continue.
- When one mimo run writes the tests and a later run writes the
  implementation, a *wrong test expectation can pull production behavior
  out of spec*: observed 2026-07-17 (Plan 181) — the test run asserted
  against `generate_html()` where the spec meant the new `snapshot()`,
  so the implementation run "fixed" the resulting failures by making
  `generate_html()` live-render by default (inverting a deliberately
  preserved legacy default) and reordering SVG attributes to fit its own
  test regex. All gates passed; the damage was only visible in the diff.
  Defenses: (a) in the test spec, name the exact assertion *target*
  (which method/field), not just the expected values; (b) in the
  implementation spec, call out preserved defaults explicitly ("when the
  new parameter is absent, output must be byte-identical — do not add
  fallbacks"); (c) on review, read every production hunk that touches a
  pre-existing code path and ask "does the default path still do what it
  did before?", not just "do the new tests pass?".

### What delegates well vs. what doesn't

Calibration from real sessions:

- **Delegates cleanly (one-pass):** read-only surveys and doc production
  (enumerate X across the codebase, classify each, write a reference
  table); applying an already-verified, literally-specified change
  (exact code to add, exact file, exact line); mechanical
  find-and-replace with a precise gate. A fold-survey task that would
  have cost the orchestrator many tokens of reading landed in ~1.5
  minutes with accurate line citations, verified by spot-check. These
  are mimo's sweet spot — use it aggressively here.
- **Does not delegate well:** anything where the *correct answer is not
  yet known* — open design questions, "figure out the right semantics
  for X," debugging an unknown failure, decisions about external tool
  behavior you haven't verified yourself. Resolve those first (this is
  the "verify first, delegate second" rule), *then* the remaining
  "apply the known answer" work becomes delegable.

When in doubt about which kind of task you have, ask: "can I write down
the exact expected output right now?" If yes → delegate. If no → it's
verify-first work; do that piece yourself, delegate the rest.

**Refinement — "verified" is not the same as "compile-clean."** A spec
whose *design* is verified (the orchestrator has reasoned through the
semantics and knows the right answer) can still contain type-level
defects that only surface at build time — a GADT constructor whose
handler has a different type index than the body (`CatTry`'s handler is
`CatOp (a, Value) b`, not `CatOp a b`), an exhaustive pattern match that
becomes non-exhaustive when a new constructor is added, a missing
`unsafeCoerce` the orchestrator didn't need to think through at design
time. In one session, a "fully verified" spec for adding a GADT
constructor + a rehydration function had *two* such defects; mimo
caught both at the build, diagnosed them correctly (grepping the
constructor's real signature, recognizing the same `unsafeCoerce`
discipline an adjacent function already uses), applied minimal fixes,
and went green — all without orchestrator intervention. **The lesson: a
well-specified task absorbs its own compile-time corrections.** Do not
over-fit a spec to prevent every conceivable type error (you will miss
some, and the attempt bloats the spec); instead, give mimo (a) the
exact intended design, (b) the non-negotiable invariants it must not
violate, and (c) a hard verification gate, and trust the build-fix loop
to close mechanical gaps — while you watch the diff afterward for any
"fix" that crosses from mechanical into behavioral.

**Refinement — when the spec itself has a semantic flaw (not just a
type-level one), mimo cannot self-correct; the orchestrator must.** A
distinct failure mode from the above: the spec's *design* contains a
genuine semantic ambiguity or flaw (not a missing `unsafeCoerce` or a
type-index mismatch, but a wrong equation or an underspecified
combinator). In one session (Plan 167 Phase 5a, 2026-07-13), the spec's
`ELet`/`EVar` fold clauses had a soundness gap: the cache-hit/miss logic
for the let-binding was underspecified, and the orchestrator's "verified"
equation was subtly wrong about what an `EVar` recovers. mimo hit a type
error on the `ELet` clause and iterated *four* times trying to close it —
each "fix" crossed further from the intended semantics (caching `id`,
making `EVar` return `id`, pinning types with `foldPure PId`). None were
correct, because the bug was in the *design*, not the *plumbing*: no
amount of type-level ingenuity rescues a wrong equation. **The signal:
when mimo iterates more than ~2× on a single clause and each fix is
plausible-looking but semantically different from the last, the spec
itself is the problem.** Kill the run, re-derive the correct semantics
yourself (in this session: a GHCi trace of the fold's actual output
settled what `ELet`/`EVar` should produce), fix the spec and the code
directly, and re-delegate only the now-mechanical remainder. The test
gate is the ground truth here: a failing assertion that contradicts
mimo's "fix" is telling you the design is wrong, not the test. (The
flip side: a test whose *expectation* was wrong — as this session's
`callCount @?= 1` initially was, testing an idealized force-time sharing
that 5a doesn't provide — is the other half of the same coin. Verify the
*test's* expectation against the actual semantics before trusting it as
the gate.)

**Refinement — a spec flaw is self-correcting WHEN the gate can see it.**
The Phase 5a failure mode above (mimo flailing 4× on a flawed
`ELet`/`EVar` clause) has a counterexample one session later (Plan 167
Phase 5b Step 1, 2026-07-13): the spec's `CatTagged bid body → ELet bid
body (EVar bid)` mapping was semantically wrong (it doubled the body's
execution; the correct mapping is plain `body`, since `CatTagged` is
identity-at-position and `Interp`'s one-arm `(|||)` runs one branch).
mimo **caught it itself** at the verification gate (the shared-tail
cross-check test failed), diagnosed the cause correctly (`foldFreyd`'s
`ELet` produces `cK . bK` = body-twice vs `foldCat`'s `CatTagged` =
body-once), and applied a sound fix — all without orchestrator
intervention. **The difference from 5a: the 5b flaw was *observable at
the gate*.** A failing cross-check test pointed unambiguously at the
wrong row of the substitution table, and the fix was "drop this row,"
not "derive the correct semantics of an underspecified combinator from
scratch." 5a's flaw lived in fold semantics that no single test failure
localized — mimo had to *invent* the right equation, which it cannot do.
**The calibration:** a spec flaw whose wrongness shows up as a concrete,
localizable test failure (a wrong cell in a table, an off-by-one, a
misplaced arm) is self-correcting via the build-fix loop — let mimo fix
it and *verify the fix is sound* afterward (trace the semantics
yourself; "the test passes" is necessary but not sufficient when the
test itself could pass for the wrong reason). A spec flaw whose
wrongness is diffuse or requires re-deriving a design decision is NOT
self-correcting — kill and re-derive. The signal that distinguishes them
is whether mimo is *converging* (each fix closer to correct, the
diagnosis pointing at a specific defect) or *flailing* (each fix a
different plausible-looking guess, the diagnosis gesturing at the whole
clause). Converging → let it run, verify after. Flailing → kill.

## Writing the spec file

- **State current file state precisely.** Paste the exact current
  relevant code (with line numbers/anchors) rather than describing it in
  prose — mimo shouldn't have to rediscover context it could just be
  given.
- **Give exact code to add or change**, not a description of the intent,
  for anything syntax- or semantics-sensitive. "Add a rule that counts
  callers" is not a spec; the literal rule text is.
- **Mark verified content as verified**, explicitly ("this has already
  been confirmed against the real X, apply exactly, do not redesign").
  This measurably changed outcomes in practice — the same kind of rule,
  handed over as "design this" vs. "here is the verified answer, apply
  it," produced flailing in the first case and a clean one-pass landing
  in the second.
- **Give a non-negotiables section**: don't improvise semantics, don't
  touch anything outside this task's file list, don't paper over a
  failing verification gate by changing the gate — stop and report the
  exact failure instead.
- **Give exact verification commands** with a concrete way to tell
  pass from fail (not "make sure it works" — an exact diff command, an
  exact expected count).
- **End with an explicit "Stop" section**: report build status, test
  count, verification-gate result, and files touched, then stop. Don't
  ask it to suggest what's next.

## mimo reads this project's AGENTS.md/CLAUDE.md too — account for that

`mimo run --dir <project-path>` operates in the project directory, so it
picks up `CLAUDE.md`/`AGENTS.md` (and nested subsystem `AGENTS.md` files,
e.g. `compiler/AGENTS.md`) the same way a Claude Code session does. This
cuts both ways and the spec should account for it rather than assume mimo
either has or lacks this context by default:

- **Helps — don't re-state baseline conventions.** Prelude rules, no-`git
  add`/`git commit`, Text-everywhere/no-partial-functions, naming
  conventions — mimo already gets these from the repo's own docs. Spend
  the spec's words on the task-specific transformation rules, not
  boilerplate the project docs already cover.
- **Misfires — protocol steps written for an interactive Claude Code
  session don't make sense headless.** This project's Staged Verification
  Loop says "stop here and wait for review" at Stage 1/Stage 3 for
  non-trivial changes — but a `mimo run --dangerously-skip-permissions`
  invocation has no one to hand a review to mid-run. Likewise,
  `compiler/AGENTS.md`'s mandatory `constraint-evasion` skill invocation on
  every Haskell diff assumes a `Skill` tool mimo doesn't have. If the
  task touches a subsystem whose `AGENTS.md` contains gates like these,
  say so explicitly in the spec's non-negotiables: e.g. "the constraint-
  evasion review this repo's `compiler/AGENTS.md` calls for happens after
  you report done, not during this run — do not attempt to invoke it,
  just finish the mechanical task and stop." Otherwise mimo may stall
  waiting on a review step that will never come, or silently skip a gate
  it can't satisfy without saying so.

## Invocation mechanics

**Primary pattern — the Bash tool's `run_in_background` option** (no
trailing `&`):

```bash
mimo run "<message>" --dir <project-path> --dangerously-skip-permissions --file=<spec-path> > <logfile> 2>&1
```

Invoke this via the Bash tool with `run_in_background: true`. This keeps
mimo attached to the harness's own background-task tracking, so the
completion notification fires on the *mimo process itself* (not on a
launcher shell). Reliability confirmed over two consecutive sessions
(Plan 167 Phase 4 folds 1 and 2, 2026-07-13): the notification fired on
the right process both times, and `pgrep -f "mimo run"` disambiguated
cleanly while the run was in flight. This is the pattern to reach for by
default.

**Fallback pattern — bare trailing `&` + `kill -0` wait-loop.** Use only
if `run_in_background` is unavailable for some reason:

```bash
mimo run "<message>" --dir <project-path> --dangerously-skip-permissions --file=<spec-path> > <logfile> 2>&1 &
MIMO_PID=$!
```

then, separately, to get notified on completion without polling:

```bash
while kill -0 $MIMO_PID 2>/dev/null; do sleep 5; done; echo "mimo done"
```

Run that second command via the Bash tool with the background option so
the harness notifies you when it exits, rather than sleeping in a loop
yourself. Caveats specific to the `&` launcher are in the gotchas below.

**Use the wait productively.** While the wait-loop runs in the
background, do the *verify-first* work for the next step yourself — the
piece that requires judgment and can't be delegated (confirming an
external CLI's actual behavior, reading a module to settle an open
design question, checking whether an output path is gitignored). This
turns the delegation latency from dead time into parallel progress and
is the pattern that makes orchestrating mimo efficient rather than just
"fire and wait." One session: mimo surveyed folds in the background
while the orchestrator verified (ahead of delegating golden capture)
that the `--dual-trace` oracle the plan relied on had been deleted in an
earlier phase — a finding that reshaped the next step and would
otherwise have been handed to mimo to rediscover, badly.

Gotchas, confirmed against the actual CLI (`mimo run --help` / `mimo
--help` disagree with each other — verify against `run --help`
specifically, don't assume a top-level flag carries over):

- `--never-ask` exists on the default `mimo [project]` TUI command but
  **not** on `mimo run` — using it there fails validation silently
  falling back to printing help. Use `--dangerously-skip-permissions` for
  `mimo run` instead.
- `-f`/`--file` is an array-typed flag in mimo's argument parser and will
  greedily consume trailing positional arguments if placed before the
  message. Always write it as `--file=<path>` (with `=`), placed after
  the message string, not `-f <path> "<message>"`.
- Redirect mimo's own stdout/stderr to a plain log file the user can
  `tail -f` independently (`> logfile 2>&1`), separate from whatever the
  harness's own background-task output capture does — the user asked for
  this explicitly after finding the harness's internal task-output file
  wasn't readily tailable.
- Launching with a bare trailing `&` (the fallback pattern above)
  detaches mimo from the harness's own background-task tracking, **but
  the harness still sends a "completed (exit code 0)" notification when
  the *launcher shell* exits** — which is immediately, because `&`
  returns right away. That notification is about the wrong process. Two
  real sessions have mistaken it for mimo's completion: one concluded
  mimo had finished (it hadn't — only the launcher shell had); the next
  saw an empty `git diff` and a 4-line log and nearly concluded mimo
  exited without doing anything, when in fact it was actively mid-task
  and went on to complete correctly. **The disambiguating check:**
  `pgrep -f "mimo run"`. If it returns a PID, mimo is still running —
  ignore the harness's launcher-shell notification and poll that PID
  yourself via the `kill -0` wait-loop. Treat the harness notification
  for an `&`-launched process as unreliable about mimo's actual state;
  the `pgrep` + log-tail are the ground truth. **This hazard is why
  `run_in_background` (the primary pattern above) is preferred: it keeps
  mimo attached to the harness's tracking, so the completion
  notification fires on the right process and the ambiguity does not
  arise.**

## Debugging a reported mismatch/failure

Before concluding a real regression, rule out **stale state**: if a
verification step reuses a file path (e.g. a `.db` file) across runs,
delete it first (`rm -f`) and rerun clean. A false "mismatch" this
session was entirely caused by comparing against a stale/aborted-run
artifact left at the same path, not any actual logic bug — always check
the run's own exit code and success marker, not just a truncated tail of
its output.

## Recognizing successful completion (don't kill a finishing run)

mimo's log does not always end with an obvious "DONE" banner. A run that
has written its target artifact, run its verification gate, and printed a
short report ("All checks pass: …") **is finished** — even if the process
PID lingers a few seconds while the CLI tears down, and even if the log's
last line is a quiet status line rather than a fanfare. Three real
misjudgments to avoid, all observed:

1. **"It reported empty `git status`, so it must not have written
   anything."** Check the *filesystem* (`ls` the expected output path),
   not just `git status`. In one session the output file landed under a
   *gitignored* directory (`doc/plan/`, ignored repo-wide), so `git
   status` was vacuously empty even though the file existed on disk and
   was correct. The vacuous gate is the hazard, not mimo's work — see the
   next section.
2. **"The PID is still alive, so it must be stuck."** A process can
   persist briefly past its final log line during teardown. Before
   killing, re-read the tail of the log: if it printed a Stop-section
   report (build status, file list, gate result), the work is done; the
   PID will exit on its own. Killing a run that already reported success
   wastes the work and forces a redo.
3. **"The harness said it completed, so it must be done."** If mimo was
   launched with `&`, the harness's "completed (exit code 0)"
   notification fires when the *launcher shell* exits — immediately —
   not when mimo finishes. One session read that notification, saw a
   4-line log and an empty `git diff`, and nearly concluded mimo had
   exited without doing anything; `pgrep -f "mimo run"` showed it was
   actively working and it went on to succeed. Full account and the
   disambiguating check are in the "Invocation mechanics" gotchas
   above.

The reliable signal of completion is the **Stop-section report itself**
(a list of gate results + files touched), not process liveness, not
git status, and not the harness's launcher-shell notification. When in
doubt, `pgrep -f "mimo run"` (is it still running?) plus `ls` the
artifact and read it.

## Verification gates can pass vacuously — check the artifact exists

A gate built on `git status`/`git diff` being empty only proves *no
tracked file changed*. It says nothing about whether the intended
*output artifact* was created if that artifact lives under a gitignored
path (this repo ignores `doc/plan/`, `BACKLOG`, `STRATEGY`, and others
by design — see `.gitignore` and `CLAUDE.md`). Observed: a read-only
doc-production task reported "✅ `git status --porcelain` empty, ✅ `git
diff --name-only` empty" — both true, both *vacuous*, because the one
file it was supposed to create is gitignored. The file was in fact
correctly written; the gate just couldn't see it.

When the deliverable is an untracked/gitignored file (plan docs,
one-off reports), make the gate **positively assert the artifact**:

- `test -f <path> && wc -l <path>` — the file exists and is non-empty.
- A structural check on its contents (`grep -c '^|' <path>` for a table
  row count; `grep -q '<required heading>' <path>`).
- Keep the `git diff --name-only`-is-empty check too — it still proves
  no *source* was touched, which is the real invariant for read-only
  tasks. Just don't let it be the *only* check.

Before writing the spec, check whether the output path is gitignored
(`git check-ignore -v <path>`). If it is, write the gate accordingly.

## When mimo appears stuck

If mimo looks like it's flailing on something genuinely subtle (not a
typo, not a missing import), that's the signal to step in — but *look at
its actual diff and log first* before killing the process. It may be
legitimately mid-way through a correct fix even if the terminal output
looks messy; killing on a snap judgment from one pasted error line cost
real time in one session (the process was, on closer inspection,
converging on a sound engine extension). Prefer: read the current diff,
form a judgment about direction of travel, and only then decide to let it
continue, correct it with a narrow follow-up, or take over the remaining
piece yourself.

The flip side, learned the hard way the session before this skill was
written: **don't mistake a *finishing* run for a *stuck* run.** A run
that has already written its artifact, passed its gate, and printed its
Stop-section report is done; the PID may linger briefly during teardown.
Re-read the log tail and `ls` the output before concluding anything is
wrong (see "Recognizing successful completion" above).

## Known Souffle/Datalog gotchas (grow this list as more are found)

These cost real iteration time and are worth checking before writing any
new Souffle rule, whether writing it yourself or specifying it for mimo:

- Aggregate syntax is `N = count : { witness(...) }` — **not** `N = count
  Var : { ... }`. `count` takes no target expression; only `sum`/`max`/
  `min`/`mean` bind a variable.
- A `count` result has Souffle type `number`. Declaring its target column
  as `unsigned` (or anything else) is a type error — use `number`.
- `count : { relation(a, b, _) }` counts **matching rows of the
  underlying relation**, regardless of which columns are wildcarded
  (`_`) vs. bound to a variable name inside the aggregate body — wildcard
  vs. named makes *no difference* to the count. To get a deduplicated
  count (e.g. "distinct callers, ignoring how many times each called"),
  the *witness relation itself* must already be projected down to only
  the columns you want distinctness over — Souffle relations are sets, so
  fact-loading naturally collapses identical tuples once the extra
  column is gone. There is no in-aggregate projection/dedup trick.
- A literal Soufflé **symbol** constant in a rule (e.g. `"high"`) must be
  written in this codebase's `Literal`/`litArgs` IR as a `Text` value that
  itself contains the embedded quote characters (Haskell:
  `"\"high\""`). A literal Soufflé **number** constant (e.g. `0`) must
  have no quotes at all (Haskell: `"0"`, just the one character). Mixing
  these up is an easy mistake to miss — double check which type the
  target column is before writing the literal.
- Verify any non-trivial new rule shape with a tiny standalone `.dl` +
  `.facts` fixture run through the real `souffle` binary before writing
  it into the codebase, every time. It takes seconds and catches
  semantic mistakes (like the aggregate-dedup one above) that reasoning
  from the Souffle documentation alone did not catch.
