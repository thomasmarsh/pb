---
name: constraint-evasion
description: >-
  Reviews a Haskell diff under compiler/ for constraint-evading behavior —
  the failure mode where an LLM keeps code compiling by suppressing a
  warning/hlint check, stuffing a string/field/sentinel into an existing
  ADT branch or record field instead of extending the type, or quietly
  weakening a type signature (NonEmpty->[], an enum->String, Ident/Lvalue
  ->Text, a real constraint->Show) relative to what was planned or what the
  surrounding domain already establishes. ALWAYS invoke this — not just
  when asked to review — before /finish or before proposing a commit for
  any session that touched compiler/, and any other time a Haskell diff in
  this repo is being reviewed. The worst instances are in code that did
  NOT change but should have (a new constructor swallowed by an old
  catch-all, a stale call site left holding the pre-change assumption), so
  this skill starts from the changed functions/types and walks outward to
  their unchanged consumers, not just the diff hunks themselves.
---

# Reviewing a Haskell diff for constraint-evading behavior

Grounded in [Justin Le's "LLMs Will Cheese Your Types"](../../../article.md):
LLMs under pressure to make code compile will reach for the path of least
resistance — suppress the check, abuse an existing type, quietly drop a
constraint — rather than doing the (often mechanical) work of extending the
type correctly. Diff views make *changed* code easy to scrutinize; they make
code that *should have changed but didn't* almost invisible. This skill's job
is to catch both halves.

This is a different lens than `/simplify` (quality, not evasion) or a general
`/code-review` (broad correctness) — run this in addition to those, not
instead of them, for any compiler/ change.

## When to run this

- Before `/finish` or any commit-message proposal for a session that touched
  `compiler/`.
- Whenever explicitly asked to review a Haskell diff in this repo.
- Mid-session, the moment a change under `compiler/` "makes the build pass"
  after friction — a failing test got easier, a compile error disappeared
  faster than expected, a warning went quiet. That friction is exactly the
  moment constraint-evading behavior happens.

## Step 0 — Scope the diff

Default to everything uncommitted under `compiler/`; accept a ref from the
user (a commit, `main`, a PR) if one is given instead.

```bash
cd compiler
git diff HEAD -- . ':!dist-newstyle'          # unstaged + staged, working tree
git status --porcelain -- .                    # catches new untracked .hs files
git diff -U0 HEAD -- .                          # zero-context, for signature/pragma greps below
```

If reviewing a range instead of working-tree changes, substitute
`git diff <base>...<head> -- compiler/` throughout.

## Step 1 — Inventory what actually changed

From the `-U0` diff, list:

- Every changed/added function type signature (`::` lines).
- Every changed/added `data`/`newtype` declaration and constructor.
- Every new or removed `{-# ... #-}` pragma line.
- Every new import (an escape hatch often arrives as a new import before
  it's ever called).

This inventory drives every later step — do not skip straight to reading the
diff top to bottom; a signature change three files away from the "main"
change is easy to miss that way.

## Step 2 — New escape hatches (cheap, do this first)

Grep the diff's **added lines only** (`^\+` in the `-U0` output, not context)
for:

```bash
git diff -U0 HEAD -- . | grep -nE '^\+.*(Wno-|OPTIONS_GHC|HLINT ignore|ANN.*"HLint)'
git diff -U0 HEAD -- . | grep -nE '^\+.*(unsafeCoerce|unsafePerformIO|Unsafe\.Coerce|Debug\.Trace)'
git diff -U0 HEAD -- . | grep -nE '^\+.*\berror\b' | grep -v 'impossible:'
git diff -U0 HEAD -- . | grep -nE '^\+import '
```

For each hit:

- **A newly added `-Wno-*`/`HLINT ignore`/`ANN` line is a hard flag.** Per
  root `AGENTS.md`, `-Wall`/`-Wincomplete-patterns` are non-negotiable and
  `cabal build` must be warning-free; a human, not the agent, decides when
  a suppression is legitimate. Flag it regardless of the stated
  justification in the diff/commit — the justification is exactly what the
  article's `P(legitimate | attempted)` argument says not to trust.
- **`unsafeCoerce`/`unsafePerformIO`/`Debug.Trace` are not automatic
  flags** — `PB.Compile.IR`/`FromSSA` already use `unsafeCoerce` legitimately
  for the effect-interpreter existential trick, and `Serialise.hs`/
  `DuckDb/PhaseB/Query.hs` already carry `-Wno-orphans` for Aeson orphan
  instances. Only flag **newly introduced** occurrences (added lines), not
  pre-existing ones the diff merely touches incidentally. If a diff *adds a
  new* `unsafeCoerce` outside the existing effect-system machinery, or a
  *new* `Wno-orphans` file, that's still a flag.
- **A bare `error` without `"impossible: <reason>"`** bypasses the
  Prelude rule that `error` is reserved for cases GHC cannot prove total.
  Check whether the case really is unreachable, or whether it's standing in
  for a case the function should instead handle in its type (a `Maybe`
  return, an `Either` branch, a new constructor).
- **New imports that reach around `PB.Prelude`** — e.g. `import Data.List
  (head)`, `import Data.Maybe (fromJust)`, or any explicit `import Prelude`
  — reintroduce a partial function the custom Prelude deliberately hides.

## Step 3 — String / field / sentinel stuffing

For every changed line in Step 1's inventory that **applies an existing**
data constructor or updates an **existing** record field (not one the diff
itself just defined), ask: does the value being carried actually match what
that constructor/field means elsewhere in the codebase?

```bash
# For a constructor C touched in the diff, find its other applications
# to establish what it's "supposed" to carry:
rg -n '\bC\b' compiler/src | grep -v ':.*--'
```

Concrete tells (per the article's "String Stuffing" / "Field Abuse"
sections):

- A `Text`/`String`/`A.Value`/`Int`/`SomeException`-typed field or
  constructor argument built via `<>`, `show`, or `T.pack` in the diff,
  where the surrounding domain type has a *different, more specific*
  constructor or field that was left untouched — i.e., a new error/state is
  being force-fit into an unrelated existing branch rather than adding one.
- A **sentinel value** standing in for "missing"/"n/a"/"unset" — `-1`, `0`,
  `""`, an epoch/zero date, `Nothing` used to mean something other than
  optionality — instead of a real `Maybe`/new constructor/dedicated type.
- An existing record field being reused for a second, unrelated purpose
  introduced by this diff (check the field's other read sites via `rg` —
  if this diff's writer and the field's original readers now disagree on
  what the field *means*, that's field abuse even if both compile).
- A list field (`[String]`, `[Text]`) gaining entries that are structurally
  a different kind of thing than its name promises (e.g. affiliations
  appended into `reportAuthors`).

This step requires reading, not just grepping — the constructor/field
*compiles* either way; only domain knowledge of what it's supposed to mean
catches the abuse.

## Step 4 — Type-signature weakening

From Step 1's list of changed `::` lines, diff each `-`/`+` pair (old vs.
new signature for the same function) and check for a weakening in either
direction — return type *or* argument type, and constraint list:

- `NonEmpty a` → `[a]` (with a new empty-list guard nearby)
- A project-specific enum/ADT → `String`/`Text`
- `Natural`/`Word` → `Int`
- A specific typeclass constraint (`Binary a =>`) → a weaker one
  (`Show a =>`)
- A record gaining fields avoided in favor of `Data.Aeson.Object`/
  `Map Text Value`/`HashMap`
- **`Ident`/`Lvalue`/`IdentSet` reverting to raw `Text`/`[Token]`** — this
  one is codebase-specific: `compiler/AGENTS.md`'s "Identifier typing is a
  standing goal" rule makes this a standing violation regardless of
  consumer count, not a judgment call.

If the session's charter names a plan file (`doc/plan/NNN-*.md` — gitignored,
read it directly, `git diff` will never show you it changed), diff the
landed signature against the plan's stated signature for the same function.
A deviation that isn't called out and justified in the conversation is a
flag per root `AGENTS.md`'s "Ignoring types in planned code" — silently
substituting a weaker type to avoid touching downstream code is exactly the
failure mode this file exists to catch.

## Step 5 — The part diffs hide: unchanged code that should have changed

This is the step most likely to be skipped, and the article calls it out
explicitly as the hardest to catch in review. For every type touched in
Step 1:

**New or changed constructor.** `rg` the *whole* tree (not just the diff)
for every consumer of that type/constructor:

```bash
rg -n '\bTypeName\b' compiler/src compiler/test
rg -n '\bConstructorName\b' compiler/src compiler/test
```

For each consumer the diff did **not** touch, check whether it's a case
match that swallows the new shape into a pre-existing wildcard/catch-all
(`_ ->`) or a dummy branch (`pure ()`, a default value) rather than genuine
logic — the article's "Resisting New Types" pattern. `-Wincomplete-patterns`
being a hard error here means a *missing* pattern would already fail to
build; the actual risk is a wildcard broad enough to compile without ever
being forced to add the new case explicitly. Prefer (and flag the absence
of) pattern matches that structurally decompose the new type rather than
falling through a `_`/default.

**Changed signature.** Find call sites the diff did **not** touch:

```bash
rg -n '\bfunctionName\b' compiler/src compiler/test
```

If the signature weakened (Step 4), check whether untouched call sites now
silently rely on the weaker guarantee (e.g. passing a value through unchecked
where the old, stronger type used to force a check at the call site).

## Step 6 — Report

Report findings with the `ReportFindings` tool, most severe first. Use one
of these category slugs so findings are scannable at a glance:

- `warning-suppression` — new `-Wno-*`/`HLINT ignore`/`ANN` pragma
- `escape-hatch` — new unjustified `error`/`unsafeCoerce`/Prelude bypass
- `string-stuffing` — existing sum-type branch abused to carry unrelated data
- `field-abuse` — existing record field reused/overloaded for a second purpose
- `sentinel-abuse` — magic value standing in for a real `Maybe`/new type
- `type-weakening` — signature/constraint weaker than plan or prior code
- `resisted-type` — new case handled via a stale catch-all/dummy branch
- `stale-consumer` — untouched call site left holding a pre-change assumption

For each finding give the concrete failure scenario (what input/state makes
the shortcut visibly wrong, not just "this is a code smell"), per the
`ReportFindings` tool's `failure_scenario` field.

## What NOT to flag

- Pre-existing suppressions/unsafe operations the diff doesn't add to or
  move (`PB.Compile.IR`/`FromSSA`'s `unsafeCoerce` for the effect
  interpreter, `Serialise.hs`/`DuckDb/PhaseB/Query.hs`'s `-Wno-orphans`) —
  these are settled architecture, not evasion, unless the diff touches that
  exact code and something about the usage changed.
- A type change that the conversation already discussed and the user
  explicitly approved — check for that discussion before flagging Step 4
  findings as unrecorded; the rule is about *undiscussed* substitutions, not
  all substitutions.
