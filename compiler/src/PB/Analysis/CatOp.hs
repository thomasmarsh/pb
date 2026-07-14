{-# LANGUAGE StrictData #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-inaccessible-code -Wno-overlapping-patterns #-}
-- | Categorical combinator GADT for PB procedure compilation.
--
-- Pure module — no I/O. The 'CatOp' type is the initial algebra
-- implementing 'Category', 'Cartesian', 'Cocartesian', and 'Effectful'.
-- This module is the categorical IR only: the typeclasses, the GADT, and
-- its instances. The surrounding pipeline lives in sibling modules (Plan
-- 151 split — this file used to also house all of the below, at 1367
-- lines mixing four separable stages):
--
--   * 'PB.Analysis.CatLower'     — SSA → 'CatOp' compilation (@compileSsa@)
--   * 'PB.Analysis.GraphBuilder' — 'CatOp' → flat @InstrGraph@ flattening
--     (the @GraphBuilder@ target), plus the public one-call entry point
--     @compileProcedureViaCatOp@
--   * 'PB.Analysis.CatInterp'    — direct Haskell execution (@Interp@ target,
--     used for testing)
--
-- Design: Monadic Freer Category with SSA variables.
-- After SSA, variables are immutable, so 'CatLookup' is a static
-- offset lookup (no dynamic string table).  'CatAssign' takes
-- @(env, Value) → env@, making the environment type active.
--
-- Branching is NOT a GADT constructor.  It is derived universally
-- from 'eval' + '(|||)': @branch cond t f = (t ||| f) . condToEither . eval cond@.
-- This eliminates redundant semantic opcodes.
module PB.Analysis.CatOp
  ( -- * Typeclasses
    Category (..)
  , Cartesian (..)
  , Cocartesian (..)
  , Effectful (..)
    -- * GADT
  , CatOp (..)
    -- * Derived combinators
  , branch
  , foldCat
  , foldCatOp
    -- * Plan 167 Phase 3 — shared-term table (intermediate representation)
  , CatTerm (..)
  , extractTable
  , inlineTable
  , feq
    -- * Plan 167 Phase 5a — the Freyd split (Pure / Eff / J)
  , Pure (..)
  , Eff (..)
  , foldFreyd
  , branchEff
  ) where

import PB.Prelude hiding (id, (.), lookup)
import qualified Prelude as P
import Unsafe.Coerce (unsafeCoerce)
import qualified Data.Map.Strict as Map
import GHC.Exts (Any)
import PB.AST.Expr (Expr (..))
import PB.Analysis.CatEval (Value (..))

-- ============================================================================
-- 1. Core Typeclasses
-- ============================================================================

-- | The base category: sequential composition.
class Category k where
  id  :: k a a
  infixr 9 .
  (.) :: k b c -> k a b -> k a c

-- | Cartesian category: products for variable bindings and tuples.
class Category k => Cartesian k where
  exl   :: k (a, b) a
  exr   :: k (a, b) b
  (&&&) :: k a b -> k a c -> k a (b, c)

-- | Cocartesian category: sums for branching and choice.
class Category k => Cocartesian k where
  inl   :: k a (Either a b)
  inr   :: k b (Either a b)
  (|||) :: k a c -> k b c -> k (Either a b) c

-- | Effectful category: PB-specific operations.
-- Separates pure structural routing from imperative side effects.
class Category k => Effectful k where
  eval       :: Expr -> k env Value
  assign     :: Text -> k (env, Value) env
  lookup     :: Text -> k env Value
  suspend    :: Text -> [Expr] -> k args ()
  callProc   :: Text -> [Expr] -> k args ()
  splitValue :: k (env, Value) (Either env env)
  -- | Procedure-terminal escape ('CatReturn'). Every target category must
  -- say what "abort past every enclosing construct" means for it — 'Interp'
  -- throws, a static-analysis target like 'PB.Analysis.SchFootprint' can
  -- just treat it as a no-op (Plan 148 Phase 3).
  ret        :: k a b
  -- | Loop combinator ('CatLoop'): run the body repeatedly while it returns
  -- 'Left', stopping at the first 'Right'. Added alongside 'ret' so
  -- 'foldCat' can be generic over any 'Effectful' instance instead of
  -- special-casing these two constructors per-interpreter.
  loopK      :: k a (Either a b) -> k a b

-- ============================================================================
-- 2. Derived Combinators
-- ============================================================================

-- | Universal categorical branching.
-- Evaluates a condition, keeps the environment context, and forks.
--
-- @branch cond thenK elseK = (thenK ||| elseK) . splitValue . (id &&& eval cond)@
branch :: (Effectful k, Cartesian k, Cocartesian k) => Expr -> k env b -> k env b -> k env b
branch cond thenK elseK = (thenK ||| elseK) . splitValue . (id &&& eval cond)

-- | 'branch' specialized to the Freyd split ('Eff'). Same equation, but the
-- pure fork @(id &&& eval cond)@ goes through the 'J' inclusion explicitly,
-- marking the pure/effectful boundary. This is what 'compileSsa' (Phase 5b)
-- emits at an 'SsaBranch'/'SsaSwitch' site: the arms are effectful 'Eff'
-- blocks, the test is a pure 'Expr', and 'EFanIn' (not 'PFork') is the
-- join — choice, not duplication (see 'EFanIn').
branchEff :: Expr -> Eff env b -> Eff env b -> Eff env b
branchEff cond thenK elseK = (thenK ||| elseK) . splitValue . J (PId &&& PEval cond)

-- | The fold 'CatOp' is initial for: interpret a compiled term into any
-- target category that implements 'Effectful'\/'Cartesian'\/'Cocartesian'
-- (Plan 148 Phase 3 — generalizes 'PB.Analysis.CatInterp.runCat', which is
-- this fold specialized to @k = Interp@). Every constructor dispatches to
-- the corresponding typeclass method; there is no other sensible definition
-- per constructor, so this is forced by the types rather than independent
-- logic to get wrong. 'CatAssignWithRhs' is not a primitive of any class —
-- it is @assign var . (id &&& eval e)@, i.e. "fork the env with the
-- evaluated rhs, then assign" (verified to reproduce 'Interp'\'s prior
-- bespoke 'CatAssignWithRhs' case exactly). 'CatTry'\'s handler is dropped
-- (matches every existing backend's placeholder — 'PB.Analysis.Cfg' does
-- not model try/catch, so 'PB.Analysis.CatLower.compileSsa' never emits
-- 'CatTry' at all: 0/7667 corpus procedures per Plan 149 Phase 0).
-- 'CatTagged' is transparent — it exists only so 'PB.Analysis.GraphBuilder'
-- can recognize repeat encounters of the same SSA block, which has no
-- meaning for any other fold target.
--
-- __'CatTagged' memoization.__ A shared merge-block DAG (the shape
-- 'PB.Analysis.CatLower.compileBlock'\'s blockId memo produces: the /same/
-- 'CatOp' heap value embedded at every fan-in predecessor of a merge block)
-- is folded once per embedding. Because that shared subterm itself contains
-- the next reconvergent fan-in, the cost is O(2^depth) in the number of
-- sequential reconvergent switches — the same class of blowup Plan 150
-- fixed for 'PB.Analysis.GraphBuilder.toLowCat'\/@compileLowCatToInstr@
-- (see the "GraphBuilder node-sharing" tests in @CatOpTest@). Nothing folded
-- a 'CatTagged'-bearing term on a hot path before Plan 163 Phase 3 wired
-- 'PB.Analysis.SchFootprint.foldSchFootprint' into
-- 'PB.Pipeline.Runner.compileOne', so this fold lacked the matching memo
-- until that wiring surfaced it (a real 1763-file corpus went from a
-- 7-minute run to a full stall at ~1261 files). The memo caches by blockId
-- on the first encounter and reuses on every repeat — sound because
-- 'CatTagged :: CatOp a b -> CatOp a b' preserves both type params, so the
-- cached result's type @k a b@ is provably what the uncached recursion
-- would have returned (same 'unsafeCoerce'-through-an-opaque-cell
-- discipline 'feq' below uses for the same GADT reason). Mirrors
-- 'toLowCat'\'s own memo exactly (Plan 150).
--
-- __Phase 4 (table-native).__ 'foldCat' now takes a 'CatTerm' (spine +
-- table) and resolves 'CatLetRef bid' by consulting the table, folding
-- the body once and caching the result — the same cache mechanism the
-- 'CatTagged' clause uses, with the body sourced from the table instead
-- of inline. The 'CatTagged' clause is retained (defensive; removed in
-- Phase 7). 'foldCatOp' is the pre-Phase-4 signature for callers folding
-- bare 'CatOp' terms with no sharing.
foldCat :: (Effectful k, Cartesian k, Cocartesian k) => CatTerm a b -> k a b
foldCat (CatTerm spine table) = fst (go spine Map.empty)
  where
    -- 'go' threads a 'Map Text Any' blockId→result cache through the term
    -- and returns @(folded result, updated cache)@. The cache flows
    -- sequentially through every binary constructor (CatCompose, CatFork,
    -- CatFanIn) so that a 'CatTagged' block discovered while folding one
    -- subterm is visible to its siblings — this is what stops a shared
    -- merge-block DAG from being re-folded once per embedding. The
    -- per-top-level-term cache starts empty, matching
    -- 'PB.Analysis.GraphBuilder.toLowCat'\'s @evalState ... Map.empty@.
    --
    -- The result type @k x y@ varies per subterm (GADT-indexed), but the
    -- cache is uniform 'Any', so returning @(k x y, Map Text Any)@ tuples
    -- threads the cache through without pinning a single @x y@ for the
    -- whole traversal — the obstruction that rules out a plain @StateT@
    -- here. This is the same explicit-(result,state)-tuple style
    -- 'collectWiring'\/'walkShared' uses in GraphBuilder.hs for the
    -- equivalent 'LowCat' dedup.
    --
    -- Soundness of the 'Any'\/'unsafeCoerce' cell: 'CatTagged :: CatOp a b
    -- -> CatOp a b' preserves both type params, so a cached @k x y@ stored
    -- under @bid@ is exactly the type the next @CatTagged bid _@ encounter
    -- expects to recover. 'compileBlock'\'s own memo (Plan 150) guarantees
    -- one canonical compiled value per @bid@ within a term, so a repeat
    -- @bid@ always carries identical content. Same discipline 'feq' uses
    -- in this module for the same GADT reason.
    go :: (Effectful k, Cartesian k, Cocartesian k)
       => CatOp x y -> Map.Map Text Any -> (k x y, Map.Map Text Any)
    go CatId                    m = (id, m)
    go (CatCompose g f)         m = case go g m of (gK, m1) -> case go f m1 of (fK, m2) -> (gK . fK, m2)
    go (CatFork l r)            m = case go l m of (lK, m1) -> case go r m1 of (rK, m2) -> (lK &&& rK, m2)
    go CatExl                   m = (exl, m)
    go CatExr                   m = (exr, m)
    go (CatConst e)             m = (eval e, m)
    go CatInl                   m = (inl, m)
    go CatInr                   m = (inr, m)
    go CatReturn                m = (ret, m)
    go (CatFanIn t f)           m = case go t m of (tK, m1) -> case go f m1 of (fK, m2) -> (tK ||| fK, m2)
    go (CatAssign var)          m = (assign var, m)
    go (CatAssignWithRhs var e) m = (assign var . (id &&& eval e), m)
    go (CatLookup var)          m = (lookup var, m)
    go (CatLoop body)           m = case go body m of (bK, m1) -> (loopK bK, m1)
    go (CatEval e)              m = (eval e, m)
    go (CatCall name args)      m = (callProc name args, m)
    go (CatSuspend eff args)    m = (suspend eff args, m)
    go CatSplitValue            m = (splitValue, m)
    go (CatTry body _handler)   m = go body m
    go (CatLetRef bid)         m = case Map.lookup bid m of
      -- Phase 4: consult the CatTerm's table at this use site. The table
      -- holds the raw monomorphic CatOp () () body that CatTagged would
      -- have inlined here (Phase 3 finding: compileSsa is uniformly
      -- CatOp () (), so the unsafeCoerce to the use-site's x y is
      -- representation-identity, same discipline feq uses). The
      -- fold-result cache (Map Text Any) is the SAME mechanism the
      -- CatTagged clause below uses: fold the body once on first
      -- encounter, cache the k x y result under bid, reuse on every
      -- repeat. Soundness identical to CatTagged's — CatLetRef preserves
      -- both type params, and compileBlock guarantees one canonical body
      -- per bid (CatOp.hs:201-203 headnote).
      Just cached -> (unsafeCoerce cached, m)
      Nothing     -> case Map.lookup bid table of
        Just body -> let (r, m') = go (unsafeCoerce body :: CatOp x y) m
                     in (r, Map.insert bid (unsafeCoerce r :: Any) m')
        Nothing   -> error ("foldCat: unbound CatLetRef " <> show bid)
    go (CatTagged bid f)        m = case Map.lookup bid m of
      -- A shared merge-block subterm (Plan 150): its fold result is
      -- identical at every embedding, so cache it under @bid@ on the first
      -- encounter and reuse on every repeat. This is the single fix point
      -- for the O(2^depth) blowup a shared 'CatTagged' DAG would otherwise
      -- cause — see the headnote above and the matching memo in
      -- 'PB.Analysis.GraphBuilder.toLowCat'.
      Just cached -> (unsafeCoerce cached, m)
      Nothing     ->
        -- Fold f with the incoming cache (not yet containing bid), then
        -- insert bid's result so siblings and later ancestors reuse it.
        -- Mirrors 'toLowCat' exactly: the first encounter of bid within
        -- f's own subterms would re-fold, but 'compileBlock' guarantees a
        -- block never contains itself, so bid cannot appear in f's own
        -- subterms — the cache only needs to cover siblings/later, which
        -- threading the cache through CatCompose/CatFork/CatFanIn (above)
        -- provides. No coerce on this return path — r is at f's own type
        -- params (x y), which 'CatTagged' preserves; only the 'Just'
        -- branch coerces.
        let (r, m') = go f m
        in (r, Map.insert bid (unsafeCoerce r :: Any) m')

-- | Fold a bare 'CatOp' (no shared-term table) — the pre-Phase-4
-- signature of 'foldCat', kept as a convenience for callers that fold
-- hand-built 'CatOp' terms with no 'CatLetRef' use sites (tests,
-- 'PB.Analysis.CatInterp.runCat'). Equivalent to
-- @foldCat (CatTerm op Map.empty)@. 'foldCat' itself now takes a
-- 'CatTerm' so it can consult the table at 'CatLetRef' use sites.
foldCatOp :: (Effectful k, Cartesian k, Cocartesian k) => CatOp a b -> k a b
foldCatOp op = foldCat (CatTerm op Map.empty)

-- ============================================================================
-- 3. The GADT: Initial Algebra
-- ============================================================================

-- | The initial algebra implementing the category interfaces for PB.
--
-- After SSA, variables are immutable definitions.  'CatLookup' resolves
-- a variable name to its SSA version (a static offset).  'CatAssign'
-- takes @(env, Value) → env@, threading the environment state.
--
-- Control flow:
--   * 'CatLoop' — iteration: body returns @Either a b@ (Left = continue, Right = break)
--   * 'CatInl'/'CatInr'/'CatFanIn' — coproduct injection and join (phi nodes)
--
-- Branching is NOT a constructor — it is derived via the @branch@ combinator.
data CatOp a b where
  -- Core Category
  CatId      :: CatOp a a
  CatCompose :: CatOp b c -> CatOp a b -> CatOp a c

  -- Cartesian (products for environment routing)
  CatFork    :: CatOp a b -> CatOp a c -> CatOp a (b, c)
  CatExl     :: CatOp (a, b) a
  CatExr     :: CatOp (a, b) b
  CatConst   :: Expr -> CatOp a Value

  -- Cocartesian (sums for branching / phi nodes)
  CatInl     :: CatOp a (Either a b)
  CatInr     :: CatOp b (Either a b)
  CatFanIn   :: CatOp a c -> CatOp b c -> CatOp (Either a b) c

  -- State Mutation (principled imperative variables)
  CatAssign       :: Text -> CatOp (env, Value) env
  CatAssignWithRhs :: Text -> Expr -> CatOp env env
  CatLookup       :: Text -> CatOp env Value

  -- Loops (via coproduct: Left = continue, Right = break)
  CatLoop    :: CatOp a (Either a b) -> CatOp a b

  -- | True procedure-terminal return (Plan 146 Phase 2i). Polymorphic in
  -- both type parameters, like 'error' — it never actually produces a
  -- value for its composition context. Unlike 'CatInr' (break), which
  -- resumes at whatever follows the *enclosing* 'CatLoop', 'CatReturn'
  -- unconditionally jumps to the true end of the whole procedure,
  -- bypassing every enclosing loop's break/post-loop continuation. Needed
  -- because 'CatLoop's own type (@CatOp a (Either a b) -> CatOp a b@) has
  -- no third state to distinguish "break" from "return" once a loop body
  -- is compiled — both used to collapse to the same 'CatInr', silently
  -- turning a 'return' inside a loop into a 'break'.
  CatReturn  :: CatOp a b

  -- Effects
  CatEval       :: Expr -> CatOp env Value
  CatCall       :: Text -> [Expr] -> CatOp args ()
  CatSuspend    :: Text -> [Expr] -> CatOp args ()
  CatSplitValue :: CatOp (env, Value) (Either env env)

  -- Error handling
  CatTry     :: CatOp a b -> CatOp (a, Value) b -> CatOp a b

  -- | Marks a subterm as the memoized compiled value of a specific SSA
  -- blockId (Plan 150). Identity in both types and execution (see 'runCat'
  -- and 'toLowCat') — its only purpose is to survive being embedded at
  -- multiple positions in the tree (once per predecessor of a merge block)
  -- so 'GraphBuilder' can recognize a repeat encounter of the same blockId
  -- and reuse the already-allocated pc instead of re-lowering (and
  -- re-allocating a full duplicate subgraph for) the same content again.
  CatTagged  :: Text -> CatOp a b -> CatOp a b

  -- | Plan 167 Phase 3 — a use site of a let-bound merge-block body.
  -- Carries ONLY the blockId name; the body lives once in the
  -- 'CatTerm' table (built by 'extractTable'). Identity in both types
  -- and execution, exactly like 'CatTagged' — the table entry under
  -- this blockId holds the body that 'CatTagged' would have inlined
  -- here. Phase 3's 'inlineTable' rehydrates 'CatLetRef bid' back to
  -- 'CatTagged bid body' so existing folds are unchanged; Phase 4
  -- makes folds table-native and 'inlineTable' is retired.
  --
  -- The table is monomorphic 'CatOp () ()' (compileSsa is monomorphic),
  -- so no 'Any'/'unsafeCoerce' is involved at the table layer. The
  -- 'CatLetRef' constructor preserves both type params (like 'CatTagged'),
  -- so the existing 'foldCat' soundness argument below (lines ~161-167)
  -- is untouched.
  CatLetRef  :: Text -> CatOp a b

-- Manual Show instance (GADTs can't derive)
instance Show (CatOp a b) where
  show CatId = "CatId"
  show (CatCompose _ _) = "CatCompose .."
  show (CatFork _ _) = "CatFork .."
  show CatExl = "CatExl"
  show CatExr = "CatExr"
  show (CatConst _) = "CatConst .."
  show CatInl = "CatInl"
  show CatInr = "CatInr"
  show CatReturn = "CatReturn"
  show (CatFanIn _ _) = "CatFanIn .."
  show (CatAssign t) = "CatAssign " <> show t
  show (CatAssignWithRhs t e) = "CatAssignWithRhs " <> show t <> " " <> show e
  show (CatLookup t) = "CatLookup " <> show t
  show (CatLoop _) = "CatLoop .."
  show (CatEval _) = "CatEval .."
  show (CatCall t _) = "CatCall " <> show t
  show (CatSuspend t _) = "CatSuspend " <> show t
  show CatSplitValue = "CatSplitValue"
  show (CatTry _ _) = "CatTry .."
  show (CatTagged t _) = "CatTagged " <> show t <> " .."
  show (CatLetRef t)   = "CatLetRef " <> show t

-- Manual Eq instance (GADTs can't derive).
-- Delegates to feq which does the coercion + structural matching.
instance Eq (CatOp a b) where
  x == y = feq x y

-- | Structural equality across type parameters.
-- Coerces to CatOp () () and pattern-matches.  Children are compared
-- via feq (not go) to avoid infinite recursion: go does the matching,
-- feq does the coercion.
feq :: CatOp a b -> CatOp a' b' -> Bool
feq x y = go (unsafeCoerce x) (unsafeCoerce y)
  where
    -- All constructors matched because unsafeCoerce can create any constructor
    -- at the CatOp () () type level, regardless of original type constraints.
    go :: CatOp () () -> CatOp () () -> Bool
    go CatId CatId = True
    go (CatCompose f g) (CatCompose f' g') = feq f f' P.&& feq g g'
    go (CatFork f g) (CatFork f' g') = feq f f' P.&& feq g g'
    go CatExl CatExl = True
    go CatExr CatExr = True
    go (CatConst e) (CatConst e') = e == e'
    go CatInl CatInl = True
    go CatInr CatInr = True
    go CatReturn CatReturn = True
    go (CatFanIn f g) (CatFanIn f' g') = feq f f' P.&& feq g g'
    go (CatAssign t) (CatAssign t') = t == t'
    go (CatAssignWithRhs t e) (CatAssignWithRhs t' e') = t == t' P.&& e == e'
    go (CatLookup t) (CatLookup t') = t == t'
    go (CatLoop f) (CatLoop f') = feq f f'
    go (CatEval e) (CatEval e') = e == e'
    go (CatCall t es) (CatCall t' es') = t == t' && es == es'
    go (CatSuspend t es) (CatSuspend t' es') = t == t' && es == es'
    go CatSplitValue CatSplitValue = True
    go (CatTry f g) (CatTry f' g') = feq f f' P.&& feq g g'
    go (CatTagged t f) (CatTagged t' f') = t == t' P.&& feq f f'
    go (CatLetRef t) (CatLetRef t') = t == t'
    go _ _ = False

-- ============================================================================
-- Plan 167 Phase 3 — the shared-term table (intermediate representation)
-- ============================================================================
--
-- A let-bound CatOp term: the spine plus a table of the named merge-block
-- bodies it references. Built once by 'extractTable' from a compiled
-- 'CatOp' (which still uses 'CatTagged' internally). The spine's
-- 'CatTagged' nodes are rewritten to 'CatLetRef' (name only); the body
-- each one stood for is recorded once in the table under its blockId.
--
-- This is an INTERMEDIATE representation, not the end-state. It makes
-- sharing visible (the body appears once, in the table, not once per
-- predecessor embedding). Phase 4 makes the folds table-native;
-- Phase 5 refines this into the two-type Freyd split ('Pure'/'Eff'/
-- 'ELet'/'EVar'). Any reader who stops here has stopped short — see
-- doc/plan/167-structural-sharing-catop-lowcat.md Phase 3.
data CatTerm a b = CatTerm (CatOp a b) (Map.Map Text (CatOp () ()))

-- | Extract the shared-term table from a compiled 'CatOp', rewriting
-- each 'CatTagged bid body' in the spine to a name-only 'CatLetRef bid'
-- and recording @body@ once under @bid@ in the table.
--
-- Two passes: (1) 'collectBodies' walks the term sharing-aware (mirrors
-- 'walkShared' in GraphBuilder.hs:160–169) and records each blockId's
-- body once, recursing into it to find nested tags; (2) 'goRewrite'
-- walks the original term and replaces each 'CatTagged bid _' with
-- 'CatLetRef bid', leaving every other constructor structurally
-- unchanged. Sharing-awareness lives entirely in pass (1); pass (2) is
-- a shallow, non-memoized structural rewrite.
--
-- Soundness of the body-discard on repeat encounters in 'collectBodies':
-- 'compileBlock'/'compileLoopBody' (CatLower.hs) guarantee one canonical
-- compiled value per blockId within a procedure's term (the same
-- guarantee 'foldCat'/'toLowCat'/'walkShared' already rely on), so a
-- repeat encounter always carries the same body. The recursion only
-- needs to cover siblings/later positions, which the 'Map'-threading
-- through 'CatCompose'/'CatFork'/'CatFanIn' provides.
--
-- The 'unsafeCoerce' on the body in 'collectBodies' is sound:
-- 'compileSsa' is monomorphic 'CatOp () ()', so every body is in fact
-- 'CatOp () ()' at every call site this phase produces. Same discipline
-- 'feq' uses at line 313.
extractTable :: CatOp a b -> CatTerm a b
extractTable op = CatTerm (goRewrite (collectBodies Map.empty op) op)
                          (collectBodies Map.empty op)
  where
    collectBodies :: Map.Map Text (CatOp () ()) -> CatOp x y -> Map.Map Text (CatOp () ())
    collectBodies acc (CatTagged bid body)
      | Map.member bid acc = acc
      | otherwise          = collectBodies (Map.insert bid (unsafeCoerce body) acc) body
    collectBodies acc (CatCompose g f) = collectBodies (collectBodies acc g) f
    collectBodies acc (CatFork l r)    = collectBodies (collectBodies acc l) r
    collectBodies acc (CatFanIn t f)   = collectBodies (collectBodies acc t) f
    collectBodies acc (CatLoop body)   = collectBodies acc body
    collectBodies acc (CatTry body h)  = collectBodies (collectBodies acc body) h
    collectBodies acc _                = acc

    goRewrite :: Map.Map Text (CatOp () ()) -> CatOp x y -> CatOp x y
    goRewrite _ (CatTagged bid _) = CatLetRef bid
    goRewrite t (CatCompose g f)  = CatCompose (goRewrite t g) (goRewrite t f)
    goRewrite t (CatFork l r)     = CatFork (goRewrite t l) (goRewrite t r)
    goRewrite t (CatFanIn a b)    = CatFanIn (goRewrite t a) (goRewrite t b)
    goRewrite t (CatLoop body)    = CatLoop (goRewrite t body)
    goRewrite t (CatTry b h)      = CatTry (goRewrite t b) (goRewrite t h)
    goRewrite _ other             = other

-- | The rehydration boundary (Phase 3 only — retired in Phase 4 once the
-- folds are table-native). Substitutes each 'CatLetRef bid' in the spine
-- with the body stored under @bid@ in the table, re-wrapped as
-- 'CatTagged bid body' so that every existing fold ('foldCat',
-- 'foldSchFootprint', 'toLowCat', 'feq') sees exactly the term shape it
-- sees today. For any term @op@ produced by 'compileSsa':
--
--   inlineTable (extractTable op)  is observationally identical to op
--
-- — the Phase 3 correctness contract: the refactor changes the
-- representation of sharing, not what a procedure computes. Verified by
-- the new test group in CatOpTest.hs and by the unchanged
-- GoldenFixtureTest + SchFootprint exact-output assertions.
inlineTable :: CatTerm a b -> CatOp a b
inlineTable (CatTerm spine table) = go spine
  where
    go :: forall x y. CatOp x y -> CatOp x y
    go (CatLetRef bid)  = case Map.lookup bid table of
      Just body -> CatTagged bid (unsafeCoerce body :: CatOp x y)
      Nothing   -> error ("inlineTable: unbound CatLetRef " <> show bid)
    go (CatCompose g f) = CatCompose (go g) (go f)
    go (CatFork l r)    = CatFork (go l) (go r)
    go (CatFanIn a b)   = CatFanIn (go a) (go b)
    go (CatLoop body)   = CatLoop (go body)
    go (CatTry b h)     = CatTry (go b) (go h)
    go other            = other

-- ============================================================================
-- 4. CatOp Instances
-- ============================================================================

instance Category CatOp where
  id  = CatId
  (.) = CatCompose

instance Cartesian CatOp where
  exl = CatExl
  exr = CatExr
  (&&&) = CatFork

instance Cocartesian CatOp where
  inl   = CatInl
  inr   = CatInr
  (|||) = CatFanIn

instance Effectful CatOp where
  eval       = CatEval
  assign     = CatAssign
  lookup     = CatLookup
  suspend    = CatSuspend
  callProc   = CatCall
  splitValue = CatSplitValue
  ret        = CatReturn
  loopK      = CatLoop

-- ============================================================================
-- 5. Plan 167 Phase 5a — the Freyd split: Pure / Eff / J
-- ============================================================================

-- The principled end-state's TYPES and FOLD. Introduced here WITHOUT
-- retargeting compileSsa (that is Phase 5b); the existing single-type CatOp
-- remains the live production IR until 5b lands. Phase 5a is verified by
-- hand-built Eff terms folded through foldFreyd and cross-checked against
-- the equivalent CatOp terms (see CatOpTest.hs "Phase 5a: Freyd split"
-- group).
--
-- KEY VERIFIED FINDING (2026-07-13): @eval@ is PURE. The plan doc's
-- principled end-state sketch originally placed @EEval@ in Eff; that is
-- wrong. @Interp@'s @eval@ (CatInterp.hs:94) is a single @gets@ — a pure
-- read of the environment, no @modify'@, no @TraceEvent@ (the TraceEvent
-- ADT, CatEval.hs:57-63, has no TeEval). @SchFootprint@'s @eval@ returns
-- @Set.empty@ unconditionally. So @eval@ lives in Pure as @PEval@; the
-- @Effectful Eff@ instance embeds it via @eval e = J (PEval e)@. See
-- doc/plan/167-structural-sharing-catop-lowcat.md §"The principled
-- end-state" (corrected).

-- | The cartesian (pure) category. Duplication is free: @'PFork' f f@ is a
-- well-formed pure morphism and always safe. Carries the structural routing
-- (identity, composition, products, sums) plus pure expression evaluation.
data Pure a b where
  PId     :: Pure a a
  PComp   :: Pure b c -> Pure a b -> Pure a c
  PFork   :: Pure a b -> Pure a c -> Pure a (b, c)
  PExl    :: Pure (a, b) a
  PExr    :: Pure (a, b) b
  PInl    :: Pure a (Either a b)
  PInr    :: Pure b (Either a b)
  PFanIn  :: Pure a c -> Pure b c -> Pure (Either a b) c
  PEval   :: Expr -> Pure a Value

instance Category Pure where
  id  = PId
  (.) = PComp

instance Cartesian Pure where
  exl = PExl
  exr = PExr
  (&&&) = PFork

instance Cocartesian Pure where
  inl   = PInl
  inr   = PInr
  (|||) = PFanIn

-- | The premonoidal (effectful) category. Sharing is NAMED, not inlined:
-- 'ELet' binds the body once under a name; 'EVar' is a use site. There is
-- NO 'EFork' — the tensor is only central, and 'ELet' is the ONLY sharing
-- form for effectful morphisms. A cartesian fork over an effectful subterm
-- must go through 'J' (embedding a 'Pure' fork), which cannot duplicate an
-- effect.
data Eff a b where
  J       :: Pure a b -> Eff a b
  ELet    :: Text -> Eff a b -> Eff b c -> Eff a c
  EVar    :: Text -> Eff a b
  EComp   :: Eff b c -> Eff a b -> Eff a c
  EAssign       :: Text -> Eff (env, Value) env
  EAssignWithRhs :: Text -> Expr -> Eff env env
  ECall         :: Text -> [Expr] -> Eff args ()
  ESuspend      :: Text -> [Expr] -> Eff args ()
  ESplitValue   :: Eff (env, Value) (Either env env)
  -- Sum-elimination (branch fan-in). The arms are effectful (compileSsa's
  -- branch targets contain assigns/calls/suspends), so they cannot live in
  -- 'Pure'; but '(|||)' is CHOICE, not duplication — @Interp@'s '(|||)'
  -- dispatches one arm at runtime (CatInterp.hs:89-91), so unlike 'PFork'
  -- it cannot duplicate an effect. This is the bug-class distinction the
  -- Freyd split rests on: 'Cartesian'/'PFork' over 'Eff' is forbidden
  -- (duplication), 'Cocartesian'/'EFanIn' over 'Eff' is sound (choice).
  EFanIn        :: Eff a c -> Eff b c -> Eff (Either a b) c
  ELoop    :: Eff a (Either a b) -> Eff a b
  EReturn  :: Eff a b

instance Category Eff where
  id  = J PId
  (.) = EComp

instance Cocartesian Eff where
  inl   = J PInl
  inr   = J PInr
  (|||) = EFanIn

instance Effectful Eff where
  eval e          = J (PEval e)
  assign var      = EAssign var
  lookup _        = error "Eff.lookup: dead (compileSsa never emits lookup)"
  suspend n as    = ESuspend n as
  callProc n as   = ECall n as
  splitValue      = ESplitValue
  ret             = EReturn
  loopK body      = ELoop body

-- | The Freyd fold: interpret an 'Eff' term into any target category that
-- implements 'Effectful'/'Cartesian'/'Cocartesian'. Every 'Eff' constructor
-- dispatches to the corresponding typeclass method; 'J' recursively folds
-- the embedded 'Pure' via 'foldPure'. One resolution helper caches by name
-- for 'ELet'/'EVar'.
foldFreyd :: forall k a b. (Effectful k, Cartesian k, Cocartesian k) => Eff a b -> k a b
foldFreyd e = fst (go e Map.empty)
  where
    foldPure :: Pure x y -> k x y
    foldPure PId           = id
    foldPure (PComp g f)   = foldPure g . foldPure f
    foldPure (PFork l r)   = foldPure l &&& foldPure r
    foldPure PExl          = exl
    foldPure PExr          = exr
    foldPure PInl          = inl
    foldPure PInr          = inr
    foldPure (PFanIn t f)  = foldPure t ||| foldPure f
    foldPure (PEval e')    = eval e'

    go :: forall x y. Eff x y -> Map.Map Text Any -> (k x y, Map.Map Text Any)
    go (J p)              m = (foldPure p, m)
    go (EComp g f)        m = case go g m of (gK, m1) -> case go f m1 of (fK, m2) -> (gK . fK, m2)
    go (EAssign var)      m = (assign var, m)
    go (EAssignWithRhs v e') m = (assign v . (id &&& eval e'), m)
    go (ECall n as)       m = (callProc n as, m)
    go (ESuspend n as)    m = (suspend n as, m)
    go ESplitValue        m = (splitValue, m)
    go (EFanIn t f)       m = case go t m of (tK, m1) -> case go f m1 of (fK, m2) -> (tK ||| fK, m2)
    go (ELoop body)       m = case go body m of (bK, m1) -> (loopK bK, m1)
    go EReturn            m = (ret, m)
    go (ELet name body cont) m =
      -- Fold the body once, cache its folded result @bK :: k a b1@ under
      -- @name@, then fold the continuation with the cache containing @name@.
      -- An @'EVar' name@ inside @cont@ recovers @bK@. The overall @ELet name
      -- body cont :: Eff a c@ folds to @cK . bK@ (run body, then cont) —
      -- sequential composition, since @cont :: Eff b1 c@ takes the body's
      -- result as its input. The cache is what lets a body bound once be
      -- referenced (and, once 5b/5c wire merge blocks, shared) without
      -- re-folding; it is the same @Any@/@unsafeCoerce@ discipline 'foldCat'
      -- uses (CatOp.hs:175-181) for the same GADT reason: @EVar name ::
      -- Eff x y@ recovers a @k a b1@ cached under @name@, sound only when
      -- @EVar@ appears at a position whose type index matches the body's
      -- (which the term's well-typedness guarantees). Phase 5d revisits
      -- typing this cache.
      case go body m of
        (bK, m1) -> case go cont (Map.insert name (unsafeCoerce bK :: Any) m1) of
          (cK, m2) -> (cK . bK, m2)
    go (EVar name) m =
      -- A use site: recover the cached folded result for @name@. Soundness
      -- mirrors 'foldCat''s 'CatLetRef' clause (CatOp.hs:203-219): the cached
      -- @k a b1@ is exactly the type this @EVar name :: Eff x y@ expects to
      -- recover, by the well-typedness of the enclosing 'ELet'.
      case Map.lookup name m of
        Just cached -> (unsafeCoerce cached, m)
        Nothing     -> error ("foldFreyd: unbound EVar " <> show name)
