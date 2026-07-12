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

## Invocation mechanics

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
yourself.

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
- Launching with a bare trailing `&` detaches the process from the
  harness's own background-task tracking, so you won't get an automatic
  completion notification — follow up immediately with the `kill -0`
  wait-loop pattern above via the Bash tool's background option so you
  do get notified.

## Debugging a reported mismatch/failure

Before concluding a real regression, rule out **stale state**: if a
verification step reuses a file path (e.g. a `.db` file) across runs,
delete it first (`rm -f`) and rerun clean. A false "mismatch" this
session was entirely caused by comparing against a stale/aborted-run
artifact left at the same path, not any actual logic bug — always check
the run's own exit code and success marker, not just a truncated tail of
its output.

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
