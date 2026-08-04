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
import qualified Data.Set as Set
import GHC.Exts (Any)
import PB.AST.Expr (Expr (..))
import PB.AST.Type (PbType)
import PB.Analysis.CallClassify (EffectTag)
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
  suspend    :: Text -> [Expr] -> Set.Set EffectTag -> k args ()
  callProc   :: Text -> [Expr] -> Set.Set EffectTag -> k args ()
  splitValue :: k (env, Value) (Either env env)
  -- | Procedure-terminal escape. Every target category must
  -- say what "abort past every enclosing construct" means for it — 'Interp'
  -- throws, a static-analysis target like 'PB.Analysis.SchFootprint' can
  -- just treat it as a no-op.
  ret        :: Expr -> k a b
  -- | Loop combinator ('ELoop'): run the body repeatedly while it returns
  -- 'Left', stopping at the first 'Right'. Added alongside 'ret' so
  -- 'foldFreyd' can be generic over any 'Effectful' instance instead of
  -- special-casing these two constructors per-interpreter.
  loopK      :: k a (Either a b) -> k a b
  -- | Categorical branching ('EFanIn'-forming), promoted from a
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
  --
  -- The middle 'Expr' is the original assignment-target expression (not
  -- reduced to its root variable) -- 'PB.Analysis.TaintEdges' is the one
  -- instance that reads it, to recover a subscripted LHS's own free
  -- identifiers (e.g. @arr[i+1] = x@ reads @i@ to address the write, a use
  -- 'PB.Compile.SSA.stmtToAssigns' would otherwise erase before this term
  -- exists). Every other instance ignores it.
  assignWithRhs :: Text -> Expr -> Expr -> k a a
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
branchEff :: Expr -> Eff env b -> Eff env b -> Int -> Eff env b
branchEff = EBranch

-- ============================================================================
-- 3. The Freyd split: Pure / Eff / J
-- ============================================================================

-- The principled end-state's TYPES and FOLD: 'Pure' is the cartesian
-- (duplication-safe) category; 'Eff' is the premonoidal (effectful)
-- category, with the 'J' constructor embedding a 'Pure' morphism.
--
-- KEY FINDING: @eval@ is PURE. @Interp@'s @eval@ is a
-- single @gets@ — a pure read of the environment, no @modify'@, no
-- @TraceEvent@ (the TraceEvent ADT has no TeEval).
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
  -- | Trailing 'Int': the originating source line (0 for a placeholder built
  -- via the 'Effectful' instance below, which carries no provenance — see
  -- its own note). Trailing 'Maybe' 'PbType': the assigned variable's
  -- declared type from 'PB.Analysis.TypeEnv.ScopedTypeEnv', or 'Nothing'
  -- when the SSA temp has no scope entry (never an error).
  EAssign       :: Text -> Int -> Maybe PbType -> Eff (env, Value) env
  -- | Trailing 'Set.Set' 'EffectTag': the full effect classification
  -- ('PB.Analysis.CallClassify.classifyEffects') for a call embedded
  -- directly in this assign's RHS (e.g. @ll_nrows = idw.rowcount()@) --
  -- 'Set.empty' when the RHS is not a call at all. Symmetric with
  -- 'ECall'\/'ESuspend's own trailing tag set below; without this field an
  -- effectful call whose result is assigned to a named variable (as opposed
  -- to the discarded @_@ target, which instead compiles straight to
  -- 'ECall'\/'ESuspend') had no way to carry its classification at all --
  -- see 'PB.Compile.FromSSA.compileAssignToEff'.
  EAssignWithRhs :: Text -> Expr -> Expr -> Int -> Maybe PbType -> Set.Set EffectTag -> Eff env env
  -- | Trailing 'Set.Set' 'EffectTag': the full effect classification
  -- ('PB.Analysis.CallClassify.classifyEffects') for this call, threaded
  -- alongside the pre-existing 'Suspends'\/'PureCall' verdict
  -- ('PB.Analysis.CallClassify.classifyExpr') that already decides which of
  -- 'ECall'\/'ESuspend' gets built -- see 'PB.Compile.FromSSA'.
  ECall         :: Text -> [Expr] -> Int -> Set.Set EffectTag -> Eff args ()
  ESuspend      :: Text -> [Expr] -> Int -> Set.Set EffectTag -> Eff args ()
  ESplitValue   :: Eff (env, Value) (Either env env)
  -- Sum-elimination (branch fan-in). The arms are effectful
  -- ('PB.Compile.FromSSA.compileSsaToEff's branch targets contain
  -- assigns/calls/suspends), so they cannot live in
  -- 'Pure'; but '(|||)' is CHOICE, not duplication — @Interp@'s '(|||)'
  -- dispatches one arm at runtime, so unlike 'PFork'
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
  -- | Trailing 'Int': the condition's own source line.
  EBranch  :: Expr -> Eff a c -> Eff a c -> Int -> Eff a c
  -- | Trailing 'Int': the loop header's own source line (the originating
  -- @BsFor@\/@BsDo@).
  ELoop    :: Eff a (Either a b) -> Int -> Eff a b
  -- | Trailing 'Int': the @return@ statement's own source line.
  EReturn  :: Expr -> Int -> Eff a b

instance Category Eff where
  id  = J PId
  (.) = EComp

instance Cocartesian Eff where
  inl   = J PInl
  inr   = J PInr
  (|||) = EFanIn

-- | This instance's own 'assign'\/'callProc'\/'suspend'\/'ret'\/'loopK'\/
-- 'assignWithRhs' carry no source line or type -- the 'Effectful' typeclass
-- method signatures deliberately don't change (see 'PB.Compile.IR.Eff''s
-- Layer 0a\/0b doc note), so there is nothing to plumb through here. This
-- path is confirmed dead in production: 'PB.Compile.FromSSA' builds every
-- real 'Eff' term via direct GADT construction (never imports 'Effectful'
-- at all), so every 0\/'Nothing' below is a placeholder for hand-built test
-- terms only, never a real compiled value. 'branchK' is unaffected — its
-- derivation never touches 'EBranch'.
instance Effectful Eff where
  eval e          = J (PEval e)
  assign var      = EAssign var 0 Nothing
  lookup _        = error "Eff.lookup: dead (compileSsa never emits lookup)"
  suspend n as tags   = ESuspend n as 0 tags
  callProc n as tags  = ECall n as 0 tags
  splitValue      = ESplitValue
  ret e           = EReturn e 0
  loopK body      = ELoop body 0
  branchK cond thenK elseK = (thenK ||| elseK) . splitValue . J (PId &&& PEval cond)
  assignWithRhs var lhs e = EAssignWithRhs var lhs e 0 Nothing Set.empty

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
    go (EBranch cond t f ln) = EBranch cond (go t) (go f) ln
    go (ELoop body ln) = ELoop (go body) ln
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
    -- The trailing line\/type fields are read-and-dropped here: 'Effectful
    -- k''s methods carry no such parameter (their signatures don't change
    -- — see 'PB.Compile.IR.Eff''s Layer 0a\/0b doc note), so a generic fold
    -- into an arbitrary target category has nothing to forward them to.
    -- Direct consumers of provenance (a future 'PB.Explain.*') walk
    -- 'Eff'\/'EffTerm' directly instead of going through this fold.
    go (EAssign var _ln _ty)      m = (assign var, m)
    go (EAssignWithRhs v lhs e' _ln _ty _tags) m = (assignWithRhs v lhs e', m)
    go (ECall n as _ln tags)   m = (callProc n as tags, m)
    go (ESuspend n as _ln tags) m = (suspend n as tags, m)
    go ESplitValue        m = (splitValue, m)
    go (EBranch cond t f _ln) m = case go t m of (tK, m1) -> case go f m1 of (fK, m2) -> (branchK cond tK fK, m2)
    go (EFanIn t f)       m = case go t m of (tK, m1) -> case go f m1 of (fK, m2) -> (tK ||| fK, m2)
    go (ELoop body _ln)   m = case go body m of (bK, m1) -> (loopK bK, m1)
    go (EReturn e _ln)    m = (ret e, m)
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
