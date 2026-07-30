---
name: ident-minting
description: >-
  Reference and decision procedure for anything touching PB.AST.Ident
  minting: adding/removing a call to mkIdent/mkIdentAt/mkIdentDerived/
  mkIdentSynthetic, deciding whether a Text/[Token] field should become
  Ident/IdentSet/Lvalue, or judging whether a "caller bridges via identOrig
  then the callee re-mints via mkIdent" gap is worth fixing and how far.
  ALWAYS read this before Stage 1 whenever a change touches Ident minting
  in this shape — not just when asked to review. Covers: mkIdent is a
  deprecated legacy shim (mkIdent = mkIdentSynthetic "unconverted mkIdent")
  being phased out, never a sanctioned call to add; Eq/Ord/Hashable on
  Ident compare only identCanon, so minting-shape changes are almost never
  a live-behavior fix, only a provenance/discipline one; and the widen-vs-
  leave-Text split when some callers already hold a real Ident and others
  don't. Haskell/compiler-specific — companion to primitive-vs-symptom
  (general producer/consumer judgment) and the standing rules in
  compiler/AGENTS.md ("Identifier typing is a standing goal", "Ident's are
  minted only at parse time"), which remain the authoritative prose; this
  skill is the worked procedure for applying them.
---

# Ident minting: what to check before touching it

`PB.AST.Ident` (`compiler/src/PB/AST/Ident.hs`) carries three fields:
`identOrig` (source casing), `identCanon` (lowercased, what `Eq`/`Ord`/
`Hashable` actually compare — provenance and casing have **zero** effect on
equality or map-key lookups), and `identSpan :: IdentProvenance`, either
`FromSource (NonEmpty SourceSpan)` (real token(s)) or `Synthetic Text` (no
span, reason recorded).

**Because `Eq`/`Ord`/`Hashable` only look at `identCanon`, a minting-shape
change is almost never fixing a live comparison/lookup bug.** The payoff is
provenance correctness for whichever downstream consumer actually reads
`identSpan` (source-nav click targets, a `FromSource`-vs-`Synthetic`
assertion) — and the discipline of retiring the deprecated shim below. Don't
write up a `mkIdent` conversion as "fixing a bug" unless a real span-reading
consumer is named; usually it's "removes a latent footgun" or "converts a
deprecated call", which is still worth doing per compiler/AGENTS.md's
standing rules, just don't overclaim behavioral impact.

## The four constructors — only one is a trap

```haskell
mkIdentAt      :: SourceSpan -> Text -> Ident         -- one real token
mkIdentDerived :: NonEmpty SourceSpan -> Text -> Ident -- 2+ real tokens assembled (e.g. `ancestor::event`)
mkIdentSynthetic :: Text -> Text -> Ident              -- no span; Text names *why*
mkIdent        :: Text -> Ident                        -- = mkIdentSynthetic "unconverted mkIdent"
```

`mkIdent` is a **legacy bridge explicitly documented for deletion** —
"every call site must be converted to `mkIdentAt`, `mkIdentDerived`, or
`mkIdentSynthetic` before this is deleted." Never add a *new* bare `mkIdent`
call, including by relocating an existing one from inside a callee to a
call site — that's not a conversion, it's moving the same debt sideways.
Any bare `mkIdent` in code you're touching gets replaced with an explicit
`mkIdentSynthetic "<specific reason>"` at minimum, even if you can't recover
a real span there.

## Step 1 — Classify what you're touching

- **A `Text`/`[Token]` field that structurally holds a PB identifier (or a
  fixed-arity compound, e.g. ancestor-class + optional override)?** → apply
  the standing-goal test below.
- **A caller bridging a real in-memory `Ident` through `identOrig` just to
  feed a `Text`-typed function that re-mints it internally?** → apply the
  widen-vs-leave-Text procedure (Step 3).
- **A bare `mkIdent` call sitting in code you're about to touch anyway?** →
  convert it regardless of the other two — see the constructors table above.

## Step 2 — The standing-goal test (Text/[Token] → Ident/IdentSet/Lvalue)

Convert unless one of these applies (name the specific reason in the Stage
1 proposal, don't default to "leave it as Text"):

- (a) genuinely unparsed/raw source (`BsRaw`, embedded SQL, arg-token lists
  not yet parsed into `Expr`)
- (b) a keyword/grammar-literal comparison, not an identifier reference
  (a token equals the literal keyword `structure`)
- (c) not structurally an identifier or small fixed compound of one
  (free-form text, a rendered display string)

"Only one call site needs it" is never a valid reason to skip this — see
root `AGENTS.md`'s "Foundational Correctness Overrides Premature-Abstraction
Caution."

## Step 3 — The widen-vs-leave-Text procedure

This is the split that's easy to get wrong: a shared function whose `Text`
param is fed by several callers, where the fix isn't uniform across them.

1. `rg -n '\bcalleeFunctionName\b' compiler/src` — enumerate every caller.
2. Classify each caller:
   - **Clean** — already holds a real in-memory `Ident` (or a value one
     `identOrig`/one hop away from one) and only converts to `Text` to
     satisfy this callee's signature.
   - **Messy** — genuinely has no real `Ident` in hand at this point (a
     rendered type name, a split substring of a compound token, a `Text`
     param itself threaded down from several functions upstream).
3. Verdict:
   - **All callers clean** → widen the callee's signature to `Ident`, drop
     the internal `mkIdent`/bridge entirely. Done.
   - **Mixed** → still widen the signature (the clean callers get a real
     fix for free, and the callee itself stops minting anything). At each
     messy caller, replace the callee's *relocated* `mkIdent` with an
     explicit `mkIdentSynthetic "<reason>"` — converts the deprecated call
     without fabricating a span that doesn't exist. State the clean/messy
     split explicitly in the Stage 1 proposal; don't silently pick one.
   - **All messy** → widening is pure churn (moves the shim, doesn't
     remove it). Leave the callee `Text`-typed; convert only its *internal*
     bare `mkIdent` to `mkIdentSynthetic "<reason>"`. If the messy callers'
     `Text` traces back to a real `Ident` several hops upstream (grep its
     origin — e.g. a module-level `identOrig . fst . srPrimaryObject`
     helper), that's a *separate*, likely larger primitive gap (the `Text`
     threading itself, not this callee) — log it to `BACKLOG.md` as its own
     future plan rather than folding it into this fix.
4. Before adding any new `mkIdentSynthetic` bridge in step 3: grep every
   consumer of the underlying fact for one that already computes it
   in-memory from a real parse-time `Ident` (`PB.Analysis.TypeEnv.
   WorkspaceEnv` is the usual home) — thread that through instead of
   minting a fresh synthetic one. This is the same check compiler/
   AGENTS.md's "Ident minting is parse-time only" rule requires before any
   span-bridge fix.

## Step 4 — Report

One or two sentences for the Stage 1 proposal: which callers are clean vs.
messy, which side(s) the fix lands on, and whether a separate BACKLOG entry
was logged for a deeper Text-threading gap found but not chased.

## Reference cases

- `ScopedTypeEnv.steObject` converted `Text` → `Ident` (all callers clean:
  `Runner.hs`'s `objIdent`, `Emit.hs`'s `objNameIdent` already held real
  Idents) — the pure "all clean" case.
- `TypeFamily.classifyFamily`'s `mkIdent` re-mints, fixed by adding real
  spans to `ObjectRow`/`StructureRow` (`orObjectSpan`/`srObjectSpan`) so the
  DB round trip stopped discarding provenance — a case where "no in-memory
  source" turned out to be fixable by adding a span column, not just
  bridging.
- `PB.Pipeline.Passes.fetchResolveInputs`'s `riInherits`/`riProcMap`/
  `riCallableProcMap` — used to re-derive via `mkIdent` from `ObjectRow`/
  `ProcRow`; fixed by threading `WorkspaceEnv`'s already-correct
  `weHierarchy`/`weProcMap` straight through instead (Step 3's "grep for an
  existing in-memory primitive" check, applied).
- `ControlHierarchy.resolveMemberChainType`/`resolveMemberChainDwBinding`'s
  `obj :: Text` param — the **mixed** case: `TypeCheck.hs`/`CallClassify.hs`
  are clean (already hold `ScopedTypeEnv`'s `steObject :: Ident`),
  `TypeResolve.hs`/`DwParamBinding.hs`/`SchFootprint.hs` are messy (their own
  `obj` is a `Text` param threaded through ~10 functions, itself tracing to
  a real Ident many hops upstream via `srFileObject` — logged separately,
  not fixed as part of this callee's signature change).
