-- | Shared runtime value model, expression evaluator, and observable trace
-- type for Plan 146's semantic-equivalence oracle.
--
-- Pure module — no I/O. 'evalExpr' is written once here so both the
-- 'PB.Analysis.CatOp' 'Interp' backend (Phase 1) and the future 'CpsGraph'
-- trace-interpreter (Phase 2) evaluate conditions/RHS values identically —
-- two independently hand-rolled evaluators that happen to disagree would be
-- a testing bug indistinguishable from a compiler bug.
module PB.Analysis.CatEval
  ( Value (..)
  , TraceEvent (..)
  , evalExpr
  ) where

import PB.Prelude
import PB.AST.Expr (BinOp (..), Expr (..), LvSegment (..), Lvalue (..))
import GHC.Generics (Generic)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Text.Read (readMaybe)

-- | Runtime value. In production this would be a sum type covering
-- PB's primitive types (int, real, string, boolean, date, time, blob).
data Value
  = VInt Int
  | VReal Double
  | VStr Text
  | VBool Bool
  | VNull
  deriving (Eq, Show, Generic)

-- | An observable effect produced while interpreting a 'CatOp' (or,
-- eventually, a 'CpsGraph') term: a variable assignment, an effect
-- invocation with its evaluated arguments, a branch decision, or a return.
-- Two executions are "equivalent" iff their traces are equal for the same
-- starting environment and the same mock suspend/call responses.
data TraceEvent
  = TeAssign  Text Value
  | TeSuspend Text [Value]
  | TeCall    Text [Value]
  | TeBranch  Bool
  | TeReturn  (Maybe Value)
  deriving (Eq, Show, Generic)

-- | Evaluate an 'Expr' against a variable environment.
--
-- Covers the subset 'PB.Analysis.CatOp.ssaValToExpr' and hand-built 'CatOp'
-- fixtures actually produce: literals, a single-segment 'ExLvalue' (SSA
-- variable references are always this shape — see 'renderSsaVar' call
-- sites), binops, 'ExNot', 'ExNeg', 'ExNull'. Everything else (multi-segment
-- or subscripted lvalues, calls, dispatch, object creation, arrays, host
-- vars, raw SQL fragments) falls back to 'VNull' — total, not a crash, since
-- none of these are expected to reach 'evalExpr' in Phase 1's scope (a
-- flat @Map Text Value@ has no field/subscript model, and call-shaped
-- expressions are Phase 2's concern once real mock responses exist).
evalExpr :: Map.Map Text Value -> Expr -> Value
evalExpr _   (ExBool b) = VBool b
evalExpr _   (ExInt t)  = VInt (fromMaybe 0 (readMaybe (T.unpack t)))
evalExpr _   (ExReal t) = VReal (fromMaybe 0.0 (readMaybe (T.unpack t)))
evalExpr _   (ExStr t)  = VStr t
evalExpr _   ExNull     = VNull
evalExpr env (ExLvalue (Lvalue [LvSegment n Nothing])) = Map.findWithDefault VNull n env
evalExpr env (ExBinOp l op r) = evalBinOp op (evalExpr env l) (evalExpr env r)
evalExpr env (ExNot e) = VBool (not (toBool (evalExpr env e)))
evalExpr env (ExNeg e) = case evalExpr env e of
  VInt i  -> VInt (negate i)
  VReal r -> VReal (negate r)
  v       -> v
evalExpr _   _ = VNull

evalBinOp :: BinOp -> Value -> Value -> Value
evalBinOp BopAdd = numericOp (+) (+)
evalBinOp BopSub = numericOp (-) (-)
evalBinOp BopMul = numericOp (*) (*)
evalBinOp BopDiv = \l r -> VReal (toDouble l / toDouble r)
evalBinOp BopPow = \l r -> VReal (toDouble l ** toDouble r)
evalBinOp BopEq  = \l r -> VBool (valEq l r)
evalBinOp BopNe  = \l r -> VBool (not (valEq l r))
evalBinOp BopLt  = \l r -> VBool (compareValues l r == LT)
evalBinOp BopGt  = \l r -> VBool (compareValues l r == GT)
evalBinOp BopLe  = \l r -> VBool (compareValues l r /= GT)
evalBinOp BopGe  = \l r -> VBool (compareValues l r /= LT)
evalBinOp BopAnd = \l r -> VBool (toBool l && toBool r)
evalBinOp BopOr  = \l r -> VBool (toBool l || toBool r)
evalBinOp BopXor = \l r -> VBool (toBool l /= toBool r)

-- | Arithmetic stays 'VInt' when both operands are; otherwise widens to
-- 'VReal'. Division/power always widen (avoids partial @div@-by-zero).
numericOp :: (Int -> Int -> Int) -> (Double -> Double -> Double) -> Value -> Value -> Value
numericOp fi _  (VInt a) (VInt b) = VInt (fi a b)
numericOp _  fd l        r        = VReal (fd (toDouble l) (toDouble r))

toDouble :: Value -> Double
toDouble (VInt i)  = fromIntegral i
toDouble (VReal r) = r
toDouble _         = 0

toBool :: Value -> Bool
toBool (VBool b) = b
toBool _         = False

valEq :: Value -> Value -> Bool
valEq (VInt a)  (VReal b) = fromIntegral a == b
valEq (VReal a) (VInt b)  = a == fromIntegral b
valEq a         b         = a == b

compareValues :: Value -> Value -> Ordering
compareValues (VStr a) (VStr b) = compare a b
compareValues a        b        = compare (toDouble a) (toDouble b)
