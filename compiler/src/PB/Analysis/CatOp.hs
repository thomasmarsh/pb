{-# LANGUAGE StrictData #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-inaccessible-code -Wno-overlapping-patterns #-}
-- | Categorical combinator GADT for PB procedure compilation.
--
-- Pure module — no I/O.  The 'CatOp' type is the initial algebra
-- implementing 'Category', 'Cartesian', 'Cocartesian', and 'Effectful'.
--
-- Compilation is polymorphic in the target category @k@:
--
--   * 'GraphBuilder' — flat CpsGraph (current TS runtime)
--   * 'WasmBuilder'  — WASM structured control flow (future)
--   * 'Interp'       — direct Haskell execution (testing)
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
    -- * GraphBuilder
  , GraphBuilder (..)
  , CpsNode (..)
  , runGraphBuilder
    -- * Interpreter
  , Interp (..)
    -- * Interpreter loop
  , interpretLoop
    -- * Placeholder types
  , Value (..)
  , Continuation (..)
  ) where

import PB.Prelude hiding (id, (.))
import qualified Prelude as P
import Unsafe.Coerce (unsafeCoerce)
import PB.AST.Expr (Expr (..))
import PB.Analysis.CpsCompile (CpsNode (..))
import GHC.Generics (Generic)

-- ============================================================================
-- Placeholder types
-- ============================================================================

-- | Runtime value.  In production this would be a sum type covering
-- PB's primitive types (int, real, string, boolean, date, time, blob).
data Value
  = VInt Int
  | VReal Double
  | VStr Text
  | VBool Bool
  | VNull
  deriving (Eq, Show, Generic)

-- | Continuation handle for a suspended computation.
data Continuation = Continuation Int  -- PC to resume at
  deriving (Eq, Show, Generic)

-- ============================================================================
-- 1. Core Typeclasses
-- ============================================================================

-- | The base category: sequential composition.
class Category k where
  id  :: k a a
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
  suspend    :: Text -> k args Continuation
  callProc   :: Text -> k args ()
  splitValue :: k (env, Value) (Either env env)

-- ============================================================================
-- 2. Derived Combinators
-- ============================================================================

-- | Universal categorical branching.
-- Evaluates a condition, keeps the environment context, and forks.
--
-- @branch cond thenK elseK = (thenK ||| elseK) . splitValue . (id &&& eval cond)@
branch :: (Effectful k, Cartesian k, Cocartesian k) => Expr -> k env b -> k env b -> k env b
branch cond thenK elseK = (thenK ||| elseK) . splitValue . (id &&& eval cond)

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
  CatAssign  :: Text -> CatOp (env, Value) env
  CatLookup  :: Text -> CatOp env Value

  -- Loops (via coproduct: Left = continue, Right = break)
  CatLoop    :: CatOp a (Either a b) -> CatOp a b

  -- Effects
  CatEval       :: Expr -> CatOp env Value
  CatCall       :: Text -> CatOp args ()
  CatSuspend    :: Text -> CatOp args Continuation
  CatSplitValue :: CatOp (env, Value) (Either env env)

  -- Error handling
  CatTry     :: CatOp a b -> CatOp (a, Value) b -> CatOp a b

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
  show (CatFanIn _ _) = "CatFanIn .."
  show (CatAssign t) = "CatAssign " <> show t
  show (CatLookup t) = "CatLookup " <> show t
  show (CatLoop _) = "CatLoop .."
  show (CatEval _) = "CatEval .."
  show (CatCall t) = "CatCall " <> show t
  show (CatSuspend t) = "CatSuspend " <> show t
  show CatSplitValue = "CatSplitValue"
  show (CatTry _ _) = "CatTry .."

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
    go (CatFanIn f g) (CatFanIn f' g') = feq f f' P.&& feq g g'
    go (CatAssign t) (CatAssign t') = t == t'
    go (CatLookup t) (CatLookup t') = t == t'
    go (CatLoop f) (CatLoop f') = feq f f'
    go (CatEval e) (CatEval e') = e == e'
    go (CatCall t) (CatCall t') = t == t'
    go (CatSuspend t) (CatSuspend t') = t == t'
    go CatSplitValue CatSplitValue = True
    go (CatTry f g) (CatTry f' g') = feq f f' P.&& feq g g'
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

-- ============================================================================
-- 5. GraphBuilder: CpsGraph Target Category
-- ============================================================================

-- | The target category for CpsGraph emission.
-- Wraps a function that allocates PC labels linearly.
-- Reuses 'CpsNode' from 'PB.Analysis.CpsCompile'.
newtype GraphBuilder a b = GraphBuilder
  { buildNodes :: Int -> ([CpsNode], Int) }

instance Category GraphBuilder where
  id = GraphBuilder (\currentPc -> ([], currentPc))
  (GraphBuilder f) . (GraphBuilder g) = GraphBuilder (\currentPc ->
    let (ng, pc')  = g currentPc
        (nf, pc'') = f pc'
    in (ng P.++ nf, pc''))

instance Cartesian GraphBuilder where
  exl = GraphBuilder (\currentPc -> ([CpsNop { npNext = currentPc + 1 }], currentPc + 1))
  exr = GraphBuilder (\currentPc -> ([CpsNop { npNext = currentPc + 1 }], currentPc + 1))
  (GraphBuilder f) &&& (GraphBuilder g) = GraphBuilder (\currentPc ->
    let (nf, pc')  = f currentPc
        (ng, pc'') = g pc'
    in (nf P.++ ng, pc''))

instance Cocartesian GraphBuilder where
  inl = GraphBuilder (\currentPc -> ([CpsNop { npNext = currentPc + 1 }], currentPc + 1))
  inr = GraphBuilder (\currentPc -> ([CpsNop { npNext = currentPc + 1 }], currentPc + 1))
  -- ||| emits a conditional dispatcher: branch node at pc, then-branch at pc+1,
  -- goto at end of then-branch to skip else, else-branch after goto, exit after else.
  -- The goto occupies a PC slot so it doesn't break the then-branch's next pointers.
  (|||) (GraphBuilder f) (GraphBuilder g) = GraphBuilder (\currentPc ->
    let thenEntry  = currentPc P.+ 1
        (nf, pcAfterThen) = f thenEntry
        gotoPc            = pcAfterThen
        elseEntry         = gotoPc P.+ 1
        (ng, pcAfterElse) = g elseEntry
        exitPc            = pcAfterElse
        branchNode = CpsBranch { brCond = ExNull, brThenPc = thenEntry, brElsePc = elseEntry }
        thenGoto   = CpsGoto { goTarget = exitPc }
    in ([branchNode] P.++ nf P.++ [thenGoto] P.++ ng, exitPc))

instance Effectful GraphBuilder where
  eval _expr  = GraphBuilder (\currentPc -> ([CpsNop { npNext = currentPc + 1 }], currentPc + 1))
  assign var  = GraphBuilder (\currentPc -> ([CpsAssign { anVar = var, anRhs = ExNull, anNext = currentPc + 1 }], currentPc + 1))
  lookup _var = GraphBuilder (\currentPc -> ([CpsNop { npNext = currentPc + 1 }], currentPc + 1))  -- TODO: emit real load node
  suspend eff = GraphBuilder (\currentPc -> ([CpsSuspend { suEffect = eff, suArgs = [], suVar = Nothing, suContinuation = currentPc + 1 }], currentPc + 1))
  callProc n  = GraphBuilder (\currentPc -> ([CpsCallProc { cpCallee = n, cpArgs = [], cpNext = currentPc + 1 }], currentPc + 1))
  splitValue  = GraphBuilder (\currentPc -> ([CpsNop { npNext = currentPc + 1 }], currentPc + 1))

-- | Run a GraphBuilder from PC 0, returning the emitted nodes.
runGraphBuilder :: GraphBuilder a b -> [CpsNode]
runGraphBuilder (GraphBuilder f) = P.fst (f 0)

-- ============================================================================
-- 6. Interpreter: Direct Haskell Execution
-- ============================================================================

-- | An execution interpreter category that maps 'CatOp a b' to
-- direct Haskell functions @a -> IO b@.
newtype Interp a b = Interp { runInterp :: a -> IO b }

instance Category Interp where
  id  = Interp P.pure
  (Interp f) . (Interp g) = Interp (\x -> g x P.>>= f)

instance Cartesian Interp where
  exl = Interp (\(a, _b) -> P.pure a)
  exr = Interp (\(_a, b) -> P.pure b)
  (Interp f) &&& (Interp g) = Interp (\x -> (,) P.<$> f x P.<*> g x)

instance Cocartesian Interp where
  inl = Interp (\a -> P.pure (Left a))
  inr = Interp (\b -> P.pure (Right b))
  (|||) (Interp f) (Interp g) = Interp (\x -> case x of
    Left  a -> f a
    Right b -> g b)

instance Effectful Interp where
  eval _expr  = Interp (\_env -> P.pure (VInt 0))  -- TODO: real eval
  assign _var = Interp (\(env, _val) -> P.pure env)  -- TODO: real assign
  lookup _var = Interp (\_env -> P.pure VNull)  -- TODO: real lookup
  suspend _e  = Interp (\_args -> P.pure (Continuation 0))  -- TODO
  callProc _n = Interp (\_args -> P.pure ())  -- TODO
  splitValue = Interp (\(env, val) -> P.pure (case val of
    VBool True  -> Left env
    VBool False -> Right env
    _           -> Right env
    ))

-- | Execute a loop via recursion.  The body returns 'Left' to continue
-- with updated state, or 'Right' to break with a final value.
interpretLoop :: Interp a (Either a b) -> Interp a b
interpretLoop (Interp body) = Interp go
  where
    go x = body x P.>>= \case
      Left  continueState -> go continueState
      Right breakState    -> P.pure breakState
