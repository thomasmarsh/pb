---
name: primitive-vs-symptom
description: >-
  Judges whether a proposed or landed fix targets the primitive that
  produces a wrong value, or only patches the site where the wrong value
  was observed. ALWAYS invoke at Stage 0b — before writing any Stage 1
  proposal — for a fix that reads from or derives from another module's
  computed output: an analysis pass on a shared ProcFlow/CFG, a UI reducer
  on an API response, a materializer on a Datalog relation, a pipeline
  stage on an upstream stage's output. Also invoke a second time before
  /finish to check the landed diff still matches the Stage 1 verdict —
  implementation sometimes drifts to the easier consumer-side patch after
  the primitive turns out to be more work than expected. Cross-subsystem:
  applies to Haskell, Python, and TypeScript equally, not just compiler/.
---

# Judging primitive vs. symptom fixes

A fix that changes output only where the bug was observed, while the
module that actually produces the wrong value is untouched, is a symptom
fix — the same wrong value still leaks out everywhere else that reads the
primitive. This is the single most common failure mode in this repo's
Stage 0 discovery: the fastest fix is almost always at the consumer, not
the source, and that speed is the trap. Stating the principle in prose
(root `AGENTS.md`'s "Primitive vs. Symptom Fixes") hasn't been enough to
stop it — the check has to run as a forced step before the proposal is
written, not be recalled from memory under time pressure. That's what this
skill is for.

**Run this:** at Stage 0b, before Stage 1 is written, for any fix that
isn't purely local to the file where the symptom appeared; again on the
actual diff before `/finish`, to catch drift from the stated verdict.

## Step 1 — Name the wrong value

State precisely what value or behavior is wrong and where it was observed
(failing test, corpus error, UI bug). That's the *symptom site* — not
necessarily the fix site.

## Step 2 — Trace to the producer

Find the module/function that actually computes the wrong value. If the
symptom site only displays or forwards a value computed elsewhere, it's a
consumer, not the producer — keep going upstream.

```bash
rg -n '<value/field/function name>' compiler/src   # or cli/, ui/src
```

## Step 3 — Enumerate other consumers

```bash
rg -n '\bproducerFunctionOrField\b' compiler/src compiler/test  # adjust root
```

List every other reader of the same value. If two or more consumers each
re-implement a rule the producer should own (a kill/use rule, a validation
rule, a formatting rule), that's confirmation: the policy belongs in the
producer as data/fields, not duplicated per-consumer.

## Step 4 — Verdict

One of:

- **Primitive fix** — the producer is wrong; the fix lands there. Other
  consumers get corrected for free; verify with their existing
  tests/corpus checks.
- **Consumer fix** — the producer's output is actually correct for its
  contract; this one consumer is misusing or misinterpreting it. State
  *why* the producer is fine — not just that only one consumer is
  affected. "Only one caller" is not a justification on its own; see root
  `AGENTS.md`'s "Foundational Correctness Overrides Premature-Abstraction
  Caution."

## Step 5 — Report the verdict

Write one or two sentences, ready to paste into the Stage 1 proposal:
named primitive, named other consumers (or "none found"), and which side
the fix lands on and why. This sentence is mandatory in every Stage 1
proposal for a non-local fix — its absence means Step 4 wasn't done.

## Second pass, before /finish

Reread Steps 1–4 against the actual diff instead of the plan. If the
landed fix drifted to the consumer side after the primitive fix turned out
to be harder than expected, say so explicitly and ask whether to redo it
or log the gap to `BACKLOG.md` per "A missed shared-primitive gap caught
later is a process gap."
