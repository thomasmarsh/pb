{-# LANGUAGE StrictData #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-inaccessible-code -Wno-overlapping-patterns #-}
-- | Categorical combinator GADT for PB procedure compilation.
--
-- Pure module — no I/O. The typeclasses ('Category', 'Cartesian',
-- 'Cocartesian', 'Effectful') plus the Freyd-split GADT pair 'Pure'/'Eff'
-- that implements them. The surrounding pipeline lives in sibling modules:
--
--   * 'PB.Compile.FromSSA'  — SSA → 'Eff' compilation (@compileSsaToEff@)
--   * 'PB.Compile.Flatten' — 'Eff' → flat @InstrGraph@ flattening
--     (the @NamedGraphBuilder@ target), plus the public one-call entry point
--     @compileProcedureViaEffTerm@
--   * 'PB.Compile.Interp'    — direct Haskell execution (@Interp@ target,
--     used for testing)
--
-- Design: Monadic Freer Category with SSA variables. After SSA, variables
-- are immutable, so a variable lookup is a static offset (no dynamic
-- string table). Assignment takes @(env, Value) → env@, making the
-- environment type active.
module PB.Compile.IR
  ( -- * Typeclasses
    Category (..)
  , Cartesian (..)
  , Cocartesian (..)
  , Effectful (..)
    -- * Derived combinators
  , branch
    -- * The Freyd split (Pure / Eff / J)
  , Pure (..)
  , Eff (..)
  , foldFreyd
  , foldFreydOp
  , branchEff
    -- * The Eff shared-term table
  , EffTerm (..)
  , extractEffTable
  , inlineEffTable
  ) where

import PB.Prelude hiding (id, (.), lookup)
import Unsafe.Coerce (unsafeCoerce)
import qualified Data.Map.Strict as Map
import GHC.Exts (Any)
import PB.AST.Expr (Expr (..))
import PB.Compile.ValueModel (Value (..))

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
  -- just treat it as a no-op.
  ret        :: k a b
  -- | Loop combinator ('ELoop'): run the body repeatedly while it returns
  -- 'Left', stopping at the first 'Right'. Added alongside 'ret' so
  -- 'foldFreyd' can be generic over any 'Effectful' instance instead of
  -- special-casing these two constructors per-interpreter.
  loopK      :: k a (Either a b) -> k a b
  -- | Categorical branching ('CatFanIn'/'EFanIn'-forming), promoted from a
  -- derived combinator to a primitive so a target category can override it
  -- with direct, simultaneous access to the condition and both arms — a
  -- generic per-constructor fold can never recover that access once each
  -- has been folded/erased independently.
  -- No default: 'Eff' has no 'Cartesian' instance and must not gain one
  -- (a cartesian fork over an effectful subterm must not typecheck), so a
  -- defaulted body requiring 'Cartesian k' is unsound for this class.
  -- Every instance defines 'branchK' explicitly instead.
  branchK    :: Expr -> k a c -> k a c -> k a c
  -- | Fused assign-with-rhs ('CatAssignWithRhs'\/'EAssignWithRhs'-forming),
  -- a fold-target primitive for the same reason 'branchK' is one, and with
  -- the same no-default treatment for the same reason: the generic
  -- derivation @assign var . (id &&& eval e)@ needs 'Cartesian k' to state
  -- as a default body, and (per the 'branchK' correction above) a
  -- per-method constraint over the class's own type variable is resolved at
  -- every call site regardless of which instance defines the method — so a
  -- constrained default would make this uncallable at @k = Eff@ again. Every
  -- instance defines it explicitly: @Interp@\/@SchFootprint@ repeat
  -- their current derivation verbatim (zero behaviour change); @Eff@'s body
  -- is just @EAssignWithRhs@ (already a fused term primitive — no derivation
  -- needed); a carrier with no value channel (a graph-flattener addressed
  -- only by continuation name, where @eval@\/'(&&&)' erase to no-ops)
  -- overrides it with direct access to the variable and the expression.
  assignWithRhs :: Text -> Expr -> k a a
  -- | Hook for a carrier that must not re-*materialize* a shared 'ELetRef'
  -- body on every occurrence, only re-*reference* it. 'foldFreyd''s own
  -- cache prevents re-folding the same blockId twice within one fold call,
  -- but the folded @k a b@ value it caches may still be invoked once per
  -- occurrence when the whole term is finally run — safe for a carrier
  -- whose values are idempotent to re-enter (choice-based 'Interp', pure-set
  -- 'SchFootprint') but not for one that allocates fresh output on every
  -- invocation (a graph builder minting new node names). Default is
  -- identity: only such a carrier needs to override it, wrapping the body
  -- with its own blockId-keyed memo before caching.
  memoTag :: Text -> k a b -> k a b
  memoTag _ r = r

-- ============================================================================
-- 2. Derived Combinators
-- ============================================================================

-- | Universal categorical branching. Evaluates a condition, keeps the
-- environment context, and forks. Used directly by any 'Effectful'
-- carrier that also has 'Cartesian'/'Cocartesian' instances (e.g.
-- 'PB.Compile.Flatten.WB', whose @branchK@ is this generic
-- derivation rather than a fused primitive — a wiring diagram wants the
-- branch condition as its own visible node, not fused into the fork the
-- way 'PB.Compile.Flatten.NGB' does it).
branch :: (Effectful k, Cartesian k, Cocartesian k) => Expr -> k env b -> k env b -> k env b
branch cond thenK elseK = (thenK ||| elseK) . splitValue . (id &&& eval cond)

-- | 'branch' specialized to the Freyd split ('Eff'). Same equation, but the
-- pure fork @(id &&& eval cond)@ goes through the 'J' inclusion explicitly,
-- marking the pure/effectful boundary. This is what
-- 'PB.Compile.FromSSA.compileSsaToEff' emits at an
-- 'SsaBranch'/'SsaSwitch' site: the arms are effectful 'Eff' blocks, the
-- test is a pure 'Expr', and 'EFanIn' (not 'PFork') is the join — choice,
-- not duplication (see 'EFanIn').
branchEff :: Expr -> Eff env b -> Eff env b -> Eff env b
branchEff = EBranch

-- ============================================================================
-- 3. The Freyd split: Pure / Eff / J
-- ============================================================================

-- The principled end-state's TYPES and FOLD: 'Pure' is the cartesian
-- (duplication-safe) category; 'Eff' is the premonoidal (effectful)
-- category, with the 'J' constructor embedding a 'Pure' morphism.
--
-- KEY FINDING: @eval@ is PURE. @Interp@'s @eval@ (CatInterp.hs:94) is a
-- single @gets@ — a pure read of the environment, no @modify'@, no
-- @TraceEvent@ (the TraceEvent ADT, CatEval.hs:57-63, has no TeEval).
-- @SchFootprint@'s @eval@ returns @Set.empty@ unconditionally. So @eval@
-- lives in Pure as @PEval@; the @Effectful Eff@ instance embeds it via
-- @eval e = J (PEval e)@.

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
-- 'ELetRef' is a name-only marker for a merge-block body recorded once in
-- an 'EffTerm''s table (see the shared-term-table section below). There is
-- NO 'EFork' — the tensor is only central. A cartesian fork over an
-- effectful subterm must go through 'J' (embedding a 'Pure' fork), which
-- cannot duplicate an effect.
data Eff a b where
  J       :: Pure a b -> Eff a b
  -- | Name-only marker — NOT a binder. Carries no body and no
  -- continuation, so it has no execution order of its own to get wrong;
  -- the body it names lives once, in the enclosing 'EffTerm''s table.
  ELetRef :: Text -> Eff a b
  EComp   :: Eff b c -> Eff a b -> Eff a c
  EAssign       :: Text -> Eff (env, Value) env
  EAssignWithRhs :: Text -> Expr -> Eff env env
  ECall         :: Text -> [Expr] -> Eff args ()
  ESuspend      :: Text -> [Expr] -> Eff args ()
  ESplitValue   :: Eff (env, Value) (Either env env)
  -- Sum-elimination (branch fan-in). The arms are effectful
  -- ('PB.Compile.FromSSA.compileSsaToEff's branch targets contain
  -- assigns/calls/suspends), so they cannot live in
  -- 'Pure'; but '(|||)' is CHOICE, not duplication — @Interp@'s '(|||)'
  -- dispatches one arm at runtime (CatInterp.hs:89-91), so unlike 'PFork'
  -- it cannot duplicate an effect. This is the bug-class distinction the
  -- Freyd split rests on: 'Cartesian'/'PFork' over 'Eff' is forbidden
  -- (duplication), 'Cocartesian'/'EFanIn' over 'Eff' is sound (choice).
  EFanIn        :: Eff a c -> Eff b c -> Eff (Either a b) c
  -- | A genuine branch primitive, not sugar for 'EFanIn'/'ESplitValue'/'J'
  -- — 'branchK' needs direct, simultaneous access to the condition and
  -- both arms, which a generic per-constructor fold can never recover once
  -- each has been folded/erased independently. Symmetric with
  -- 'EAssignWithRhs' (also a fused term primitive, not a derived
  -- composition). 'branchEff' is now just @EBranch@; the structural
  -- expansion this replaces is still what every existing instance's
  -- 'branchK' body computes — behaviour-preserving.
  EBranch  :: Expr -> Eff a c -> Eff a c -> Eff a c
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
  branchK cond thenK elseK = (thenK ||| elseK) . splitValue . J (PId &&& PEval cond)
  assignWithRhs var e = EAssignWithRhs var e

-- ============================================================================
-- 4. The Eff shared-term table
-- ============================================================================
--
-- 'ELetRef' carries NO body (@ELetRef :: Text -> Eff a b@, name-only) — a
-- bare 'Eff' value with 'ELetRef' markers in it has nothing left for a
-- generic walk to recover a body from. So 'extractEffTable' is necessarily
-- degenerate on any term already in 'ELetRef' form (there are no bodies
-- embedded to collect — see below); the real table is built during
-- compilation, by 'PB.Compile.FromSSA' threading an accumulator
-- alongside its per-block memo, inserting each shared block's body into
-- the table under its blockId as it is compiled. 'extractEffTable' is the
-- correct (and, for a term built entirely from 'J'/'EComp'/etc with no
-- pre-existing 'ELetRef', exact) answer for a sharing-free term, and
-- completes the 'inlineEffTable' round-trip API test-writers expect.
data EffTerm a b = EffTerm (Eff a b) (Map.Map Text (Eff () ()))

-- | Wrap a bare 'Eff' term with an empty table. Correct (not an
-- approximation) for any term with no 'ELetRef' in it, which is every
-- hand-built term in this module's own test suite and every term this
-- function can actually inspect: 'ELetRef' carries no body, so no walk
-- over a bare 'Eff' value can ever populate a non-trivial table — see the
-- headnote above.
extractEffTable :: Eff a b -> EffTerm a b
extractEffTable eff = EffTerm eff Map.empty

-- | Substitute each 'ELetRef bid' in the spine with the body stored under
-- @bid@ in the table. There is no wrapper to restore — the body is
-- spliced in directly.
inlineEffTable :: EffTerm a b -> Eff a b
inlineEffTable (EffTerm spine table) = go spine
  where
    go :: forall x y. Eff x y -> Eff x y
    go (ELetRef bid)  = case Map.lookup bid table of
      Just body -> unsafeCoerce body :: Eff x y
      Nothing   -> error ("inlineEffTable: unbound ELetRef " <> show bid)
    go (EComp g f)    = EComp (go g) (go f)
    go (EFanIn a b)   = EFanIn (go a) (go b)
    go (EBranch cond t f) = EBranch cond (go t) (go f)
    go (ELoop body)   = ELoop (go body)
    go other          = other

-- | The Freyd fold: interpret an 'EffTerm' into any target category that
-- implements 'Effectful'/'Cartesian'/'Cocartesian'. Every 'Eff' constructor
-- dispatches to the corresponding typeclass method; 'J' recursively folds
-- the embedded 'Pure' via 'foldPure'. 'ELetRef' is resolved by a cache
-- keyed on blockId alone: fold the table's body once on first encounter,
-- cache the @k a b@ result under @bid@, reuse on every repeat.
foldFreyd :: forall k a b. (Effectful k, Cartesian k, Cocartesian k) => EffTerm a b -> k a b
foldFreyd (EffTerm spine table) = fst (go spine Map.empty)
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
    go (EAssignWithRhs v e') m = (assignWithRhs v e', m)
    go (ECall n as)       m = (callProc n as, m)
    go (ESuspend n as)    m = (suspend n as, m)
    go ESplitValue        m = (splitValue, m)
    go (EBranch cond t f) m = case go t m of (tK, m1) -> case go f m1 of (fK, m2) -> (branchK cond tK fK, m2)
    go (EFanIn t f)       m = case go t m of (tK, m1) -> case go f m1 of (fK, m2) -> (tK ||| fK, m2)
    go (ELoop body)       m = case go body m of (bK, m1) -> (loopK bK, m1)
    go EReturn            m = (ret, m)
    go (ELetRef bid)      m = case Map.lookup bid m of
      Just cached -> (unsafeCoerce cached, m)
      Nothing     -> case Map.lookup bid table of
        Just body -> let (r, m') = go (unsafeCoerce body :: Eff x y) m
                         r'       = memoTag bid r
                     in (r', Map.insert bid (unsafeCoerce r' :: Any) m')
        Nothing   -> error ("foldFreyd: unbound ELetRef " <> show bid)

-- | Fold a bare 'Eff' term (no shared-term table) — the simpler signature
-- of 'foldFreyd', kept for callers folding hand-built terms with no
-- 'ELetRef' use sites (this module's own test fixtures). Equivalent to
-- @foldFreyd (extractEffTable eff)@.
foldFreydOp :: (Effectful k, Cartesian k, Cocartesian k) => Eff a b -> k a b
foldFreydOp eff = foldFreyd (extractEffTable eff)
