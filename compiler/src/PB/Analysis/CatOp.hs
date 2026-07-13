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
foldCat :: (Effectful k, Cartesian k, Cocartesian k) => CatOp a b -> k a b
foldCat op = fst (go op Map.empty)
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
    go _ _ = False

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
