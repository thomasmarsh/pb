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
under pressure to compile, LLMs suppress checks, abuse existing types, or
quietly drop constraints instead of extending the type correctly. Diffs make
*changed* code easy to scrutinize but hide code that *should have changed and
didn't* — this skill covers both. Different lens than `/simplify` (quality)
or `/code-review` (broad correctness); run in addition to those.

**Run this:** before `/finish`/any commit proposal touching `compiler/`; when
asked to review a Haskell diff; mid-session the moment a change "makes the
build pass" faster than expected (a test got easier, a warning went quiet) —
that friction is exactly when evasion happens.

## Step 0 — Scope the diff

```bash
cd compiler
git diff HEAD -- . ':!dist-newstyle'   # unstaged + staged
git status --porcelain -- .            # new untracked .hs files
git diff -U0 HEAD -- .                 # zero-context, for greps below
```

Given a ref instead, substitute `git diff <base>...<head> -- compiler/`.

## Step 1 — Inventory what changed

From the `-U0` diff, list: every changed/added function signature (`::`
lines), every changed/added `data`/`newtype` decl and constructor, every new
`{-# ... #-}` pragma, every new import. Read this list, don't just scroll the
diff top to bottom — a signature change three files away is easy to miss.

## Step 2 — New escape hatches

```bash
git diff -U0 HEAD -- . | grep -nE '^\+.*(Wno-|OPTIONS_GHC|HLINT ignore|ANN.*"HLint)'
git diff -U0 HEAD -- . | grep -nE '^\+.*(unsafeCoerce|unsafePerformIO|Unsafe\.Coerce|Debug\.Trace)'
git diff -U0 HEAD -- . | grep -nE '^\+.*\berror\b' | grep -v 'impossible:'
git diff -U0 HEAD -- . | grep -nE '^\+import '
```

- Newly added `-Wno-*`/`HLINT ignore`/`ANN` → hard flag regardless of stated
  justification (`-Wall` is non-negotiable per root `AGENTS.md`; only a
  human waives it).
- `unsafeCoerce`/`unsafePerformIO`/`Debug.Trace` aren't automatic flags —
  `PB.Compile.IR`/`FromSSA` and `Serialise.hs`/`DuckDb/PhaseB/Query.hs`
  already carry legitimate ones. Flag only *newly introduced* occurrences
  outside that existing machinery.
- Bare `error` without `"impossible: <reason>"` → check if the case is truly
  unreachable or should be a `Maybe`/`Either`/new constructor instead.
- New imports reaching around `PB.Prelude` (`Data.List (head)`,
  `Data.Maybe (fromJust)`, explicit `import Prelude`) reintroduce a partial
  function the custom Prelude hides.

## Step 3 — String / field / sentinel stuffing

For each changed line that applies an **existing** constructor or updates an
**existing** record field (not one the diff just defined): does the value
carried match what that constructor/field means elsewhere?

```bash
rg -n '\bC\b' compiler/src | grep -v ':.*--'   # other uses of constructor C
```

Tells: a `Text`/`String`/`A.Value`/`Int`/`SomeException` field built via
`<>`/`show`/`T.pack` where a more specific constructor/field exists but was
left untouched; a sentinel (`-1`, `0`, `""`, epoch date, `Nothing`-meaning-
something-else) standing in for a real `Maybe`/new constructor; an existing
field reused for a second, unrelated purpose (check its other read sites —
if writer and original readers now disagree on meaning, that's abuse even if
it compiles); a list field (`[String]`, `[Text]`) gaining structurally
different entries than its name promises. Requires reading, not just
grepping — it compiles either way; only domain knowledge catches the abuse.

## Step 4 — Type-signature weakening

For each changed `::` line, diff old vs. new and check for weakening (return
*or* argument type, or constraint list):

- `NonEmpty a` → `[a]` (with a new empty-list guard nearby)
- project enum/ADT → `String`/`Text`
- `Natural`/`Word` → `Int`
- specific constraint (`Binary a =>`) → weaker one (`Show a =>`)
- record fields avoided in favor of `Aeson.Object`/`Map Text Value`/`HashMap`
- **`Ident`/`Lvalue`/`IdentSet` reverting to raw `Text`/`[Token]`** —
  standing violation per `compiler/AGENTS.md`'s "Identifier typing is a
  standing goal," regardless of consumer count.

If the charter names a plan file (`doc/plan/NNN-*.md`, gitignored — read it
directly), diff the landed signature against the plan's stated one. An
undiscussed deviation is a flag per root `AGENTS.md`'s "Ignoring types in
planned code."

## Step 5 — Unchanged code that should have changed

The step most likely to be skipped. For every type touched in Step 1:

```bash
rg -n '\bTypeName\b' compiler/src compiler/test
rg -n '\bConstructorName\b' compiler/src compiler/test
rg -n '\bfunctionName\b' compiler/src compiler/test   # for changed signatures
```

For each untouched consumer: does it swallow a new constructor into a
pre-existing `_ ->` wildcard or dummy branch (`pure ()`, a default) instead
of genuine logic? `-Wincomplete-patterns` catches a *missing* pattern, not a
wildcard broad enough to compile without ever handling the new case — prefer
and flag the absence of structural decomposition. For a weakened signature
(Step 4), check whether untouched call sites now silently rely on the
weaker guarantee.

## Step 6 — Report

Use `ReportFindings`, most severe first, with category slugs:
`warning-suppression`, `escape-hatch`, `string-stuffing`, `field-abuse`,
`sentinel-abuse`, `type-weakening`, `resisted-type`, `stale-consumer`. Give
the concrete failure scenario (what input/state makes it visibly wrong) per
the tool's `failure_scenario` field, not just "code smell."

## What NOT to flag

- Pre-existing suppressions/unsafe ops the diff doesn't add to or move
  (`PB.Compile.IR`/`FromSSA`'s `unsafeCoerce`, `Serialise.hs`/
  `DuckDb/PhaseB/Query.hs`'s `-Wno-orphans`) — settled architecture, unless
  the diff touches that exact code and the usage changed.
- A type change the conversation already discussed and the user approved —
  check before flagging Step 4 findings; the rule is about *undiscussed*
  substitutions.
