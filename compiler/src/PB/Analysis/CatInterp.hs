{-# LANGUAGE StrictData #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
-- | Direct Haskell execution of a compiled 'CatOp' term — the @Interp@
-- target. Used for testing: evaluating a compiled procedure without going
-- through the 'PB.Analysis.GraphBuilder' flattening step or the TS runtime.
--
-- Split out of 'PB.Analysis.CatOp' in Plan 151. Parallels
-- 'PB.Analysis.CpsInterp' (the flat @CpsGraph@-level trace interpreter) —
-- 'CatInterp' interprets 'CatOp' terms directly, 'CpsInterp' interprets the
-- flattened output of 'PB.Analysis.GraphBuilder'; the two backends are
-- cross-checked against each other by Plan 146's semantic-equivalence
-- oracle tests.
module PB.Analysis.CatInterp
  ( Interp (..)
  , InterpState (..)
  , ReturnUnwind (..)
  , runInterpIO
  , runCat
  , interpretLoop
  ) where

import PB.Prelude hiding (id, (.), lookup)
import qualified Prelude as P
import Control.Monad.State.Strict (StateT, get, modify', gets, evalStateT)
import Control.Monad.IO.Class (liftIO)
import Control.Exception (Exception, throwIO)
import PB.Analysis.CatOp (Category (..), Cartesian (..), Cocartesian (..), Effectful (..), CatOp (..))
import PB.Analysis.CatEval (Value (..), TraceEvent (..), MockResponses, evalExprMocked)
import qualified Data.Map.Strict as Map

-- ============================================================================
-- Interpreter: Direct Haskell Execution
-- ============================================================================

-- | Persistent state threaded through an 'Interp' run: the named-variable
-- environment ('CatOp'\'s @env@ type parameter is structural wiring only —
-- 'PB.Analysis.CatLower.compileSsa' always produces @CatOp () ()@ — so real
-- variable storage lives here instead), the accumulating observable trace,
-- and the mocked call\/suspend responses available for this run (Plan 146
-- Phase 2a) — read-only from 'Interp'\'s own perspective, but threaded
-- through the same state for simplicity rather than adding a separate
-- 'ReaderT' layer.
--
-- 'isTrace' accumulates newest-first (prepend is O(1)); reverse once when
-- reading it back out.
data InterpState = InterpState
  { isEnv   :: Map.Map Text Value
  , isTrace :: [TraceEvent]
  , isMocks :: MockResponses
  }

-- | Thrown by 'CatReturn' (Plan 146 Phase 2i) to unwind the 'Interp'
-- backend's plain function composition straight past every enclosing loop
-- (however deeply nested) and any post-loop continuation, landing exactly
-- where the currently-running procedure was invoked from. Carries the
-- 'InterpState' snapshot taken at the point of the throw — 'StateT's own
-- state isn't otherwise recoverable across an IO exception, since the whole
-- @(a, s)@ pair is discarded the instant the underlying 'IO' action throws.
-- A caller that wants the final env/trace after a return (e.g. a test
-- harness running one whole compiled procedure via 'runCat') catches this
-- and uses the carried state directly.
newtype ReturnUnwind = ReturnUnwind InterpState

instance Show ReturnUnwind where
  show _ = "ReturnUnwind"

instance Exception ReturnUnwind

-- | An execution interpreter category that maps 'CatOp a b' to direct
-- Haskell functions @a -> StateT InterpState IO b@.
newtype Interp a b = Interp { runInterp :: a -> StateT InterpState IO b }

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
  eval expr = Interp (\_env -> gets (\st -> evalExprMocked (isMocks st) (isEnv st) expr))

  assign var = Interp (\(env, val) -> do
    modify' (\st -> st { isEnv   = Map.insert var val (isEnv st)
                        , isTrace = TeAssign var val : isTrace st })
    P.pure env)

  lookup var = Interp (\_env -> gets (Map.findWithDefault VNull var P.. isEnv))

  suspend effect args = Interp (\_env -> do
    vals <- gets (\st -> map (evalExprMocked (isMocks st) (isEnv st)) args)
    modify' (\st -> st { isTrace = TeSuspend effect vals : isTrace st }))

  callProc name args = Interp (\_env -> do
    vals <- gets (\st -> map (evalExprMocked (isMocks st) (isEnv st)) args)
    modify' (\st -> st { isTrace = TeCall name vals : isTrace st }))

  splitValue = Interp (\(env, val) -> do
    let taken = case val of
          VBool b -> b
          _       -> False
    modify' (\st -> st { isTrace = TeBranch taken : isTrace st })
    P.pure (if taken then Left env else Right env))

-- | Execute a loop via recursion.  The body returns 'Left' to continue
-- with updated state, or 'Right' to break with a final value.
interpretLoop :: Interp a (Either a b) -> Interp a b
interpretLoop (Interp body) = Interp go
  where
    go x = body x P.>>= \case
      Left  continueState -> go continueState
      Right breakState    -> P.pure breakState

-- | Run an 'Interp' morphism against a fresh, empty environment/trace/mock
-- table, discarding the final 'InterpState' — a compatibility shim for tests
-- that only care about the plain @IO b@ result (predates trace/env
-- threading).
runInterpIO :: Interp a b -> a -> IO b
runInterpIO (Interp f) x = evalStateT (f x) (InterpState Map.empty [] Map.empty)

-- | Interpret a compiled 'CatOp' term directly via 'Interp' — the fold
-- 'CatOp' is initial for. Every constructor dispatches to the corresponding
-- 'Category'\/'Cartesian'\/'Cocartesian'\/'Effectful' method on 'Interp';
-- there is no other sensible definition per constructor, so this is
-- forced by the types rather than independent logic to get wrong.
--
-- 'CatAssign'\/'CatLookup'\/'CatExl'\/'CatExr'\/'CatConst' are declared by
-- the GADT/typeclasses but never emitted by 'PB.Analysis.CatLower.compileSsa'
-- (which always emits 'CatAssignWithRhs' directly) — they're handled here for
-- completeness, not because real compiled terms use them.
--
-- 'CatTry' has no real interpretation yet: 'PB.Analysis.CfgBuild' doesn't
-- model try/catch, so 'compileSsa' never emits it either. Running the body
-- and ignoring the handler is a placeholder to keep this fold total; revisit
-- once try/catch compilation lands.
runCat :: CatOp a b -> Interp a b
runCat CatId                  = id
runCat (CatCompose g f)       = runCat g . runCat f
runCat (CatFork l r)          = runCat l &&& runCat r
runCat CatExl                 = exl
runCat CatExr                 = exr
runCat (CatConst e)           = eval e
runCat CatInl                  = inl
runCat CatInr                  = inr
runCat CatReturn               = Interp (\_ -> do
  st <- get
  liftIO (throwIO (ReturnUnwind st)))
runCat (CatFanIn t f)          = runCat t ||| runCat f
runCat (CatAssign var)         = assign var
runCat (CatAssignWithRhs var e) = Interp (\env -> do
  val <- gets (\st -> evalExprMocked (isMocks st) (isEnv st) e)
  modify' (\st -> st { isEnv   = Map.insert var val (isEnv st)
                      , isTrace = TeAssign var val : isTrace st })
  P.pure env)
runCat (CatLookup var)         = lookup var
runCat (CatLoop body)          = interpretLoop (runCat body)
runCat (CatEval e)             = eval e
runCat (CatCall name args)     = callProc name args
runCat (CatSuspend eff args)   = suspend eff args
runCat CatSplitValue           = splitValue
runCat (CatTry body _handler)  = runCat body
runCat (CatTagged _ f)         = runCat f
