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
  , MockResponses
  , evalExpr
  , evalExprMocked
  ) where

import PB.Prelude
import PB.AST.Expr (BinOp (..), Expr (..), LvSegment (..), Lvalue (..))
import PB.Analysis.CallClassify (calleeName)
import PB.Analysis.CpsCompile (parseArgList)
import PB.Lexing.Token (Token)
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
  deriving (Ord, Show, Generic)

-- | Structural equality treating NaN as equal to itself, unlike 'Double's own
-- 'Eq' instance. This type's equality is used to diff two independently
-- compiled traces for behavioral equivalence (Plan 146's @--dual-trace@);
-- under IEEE754 semantics @NaN /= NaN@ would make two runs that both
-- legitimately produce the same NaN (e.g. a @0.0/0.0@ ratio) look like a
-- divergence when there is none.
instance Eq Value where
  VInt a  == VInt b  = a == b
  VReal a == VReal b = a == b || (isNaN a && isNaN b)
  VStr a  == VStr b  = a == b
  VBool a == VBool b = a == b
  VNull   == VNull   = True
  _       == _       = False

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

-- | A recorded call/suspend response: @(calleeName, evaluated-args) -> result@,
-- shared by both interpreters so the same @(effect, args)@ pair always
-- resolves to the same mocked value in a given comparison (Plan 146 Phase 2).
type MockResponses = Map.Map (Text, [Value]) Value

-- | Evaluate an 'Expr' against a variable environment, with no mock
-- responses available — the back-compat entry point every pre-Phase-2 call
-- site and test still uses. Call-shaped expressions fall back to 'VNull'
-- here purely because an empty 'MockResponses' table can never produce a
-- hit, not because of any special-casing of their own.
evalExpr :: Map.Map Text Value -> Expr -> Value
evalExpr = evalExprMocked Map.empty

-- | Evaluate an 'Expr' against a variable environment and a table of mocked
-- call\/suspend responses.
--
-- Covers the subset 'PB.Analysis.CatOp.ssaValToExpr' and hand-built 'CatOp'
-- fixtures actually produce: literals, a single-segment 'ExLvalue' (SSA
-- variable references are always this shape — see 'renderSsaVar' call
-- sites), binops, 'ExNot', 'ExNeg', 'ExNull'. 'ExCall'\/'ExMethodCall' —
-- the shape 'PB.Analysis.CatOp.compileAssign' embeds directly for @x = f()@,
-- never as a 'CatSuspend'\/'CatCall' node with a result slot — resolve via
-- 'MockResponses', keyed on 'calleeName' and the evaluated argument list
-- (raw argument token lists are parsed with the same
-- 'PB.Analysis.CpsCompile.parseArgList' the compiled pipeline itself uses,
-- so the key matches what a real call site would look like). A miss, and
-- everything else (multi-segment or subscripted lvalues, dispatch, object
-- creation, arrays, host vars, raw SQL fragments), falls back to 'VNull' —
-- total, not a crash.
evalExprMocked :: MockResponses -> Map.Map Text Value -> Expr -> Value
evalExprMocked _     _   (ExBool b) = VBool b
evalExprMocked _     _   (ExInt t)  = VInt (fromMaybe 0 (readMaybe (T.unpack t)))
evalExprMocked _     _   (ExReal t) = VReal (fromMaybe 0.0 (readMaybe (T.unpack t)))
evalExprMocked _     _   (ExStr t)  = VStr t
evalExprMocked _     _   ExNull     = VNull
evalExprMocked _     env (ExLvalue (Lvalue [LvSegment n Nothing])) = Map.findWithDefault VNull n env
evalExprMocked mocks env (ExBinOp l op r) = evalBinOp op (evalExprMocked mocks env l) (evalExprMocked mocks env r)
evalExprMocked mocks env (ExNot e) = VBool (not (toBool (evalExprMocked mocks env e)))
evalExprMocked mocks env (ExNeg e) = case evalExprMocked mocks env e of
  VInt i  -> VInt (negate i)
  VReal r -> VReal (negate r)
  v       -> v
evalExprMocked mocks env e@(ExCall _ rawArgs) = lookupMock mocks env e rawArgs
evalExprMocked mocks env e@(ExMethodCall _ _ rawArgs) = lookupMock mocks env e rawArgs
evalExprMocked _     _   _ = VNull

-- | Shared call-resolution step for 'ExCall'\/'ExMethodCall': parse each raw
-- argument's token list into an 'Expr' (via 'parseArgList', the same parser
-- the compiled pipeline uses for call arguments), evaluate it, and look up
-- @(calleeName, evaluatedArgs)@ in the mock table.
lookupMock :: MockResponses -> Map.Map Text Value -> Expr -> [[Token]] -> Value
lookupMock mocks env e rawArgs =
  let argVals = map (evalExprMocked mocks env . parseArgList) rawArgs
  in Map.findWithDefault VNull (calleeName e, argVals) mocks

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
