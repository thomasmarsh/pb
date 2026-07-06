module CatEvalTest (tests) where

import PB.Prelude
import PB.AST.Expr (BinOp (..), Expr (..), LvSegment (..), Lvalue (..))
import PB.Analysis.CatEval (Value (..), MockResponses, evalExpr, evalExprMocked)
import PB.Lexing.Token (Token (..), TokenKind (..), SourceSpan (..))

import qualified Data.Map.Strict as Map
import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

emptyEnv :: Map.Map Text Value
emptyEnv = Map.empty

mkTok :: TokenKind -> Text -> Token
mkTok k t = Token k t (SourceSpan 1 1 1)

tests :: TestTree
tests = testGroup "CatEval"
  [ testGroup "evalExpr / literals"
    [ testCase "ExBool True" $ evalExpr emptyEnv (ExBool True) @?= VBool True
    , testCase "ExBool False" $ evalExpr emptyEnv (ExBool False) @?= VBool False
    , testCase "ExInt parses to VInt" $ evalExpr emptyEnv (ExInt "42") @?= VInt 42
    , testCase "ExReal parses to VReal" $ evalExpr emptyEnv (ExReal "3.5") @?= VReal 3.5
    , testCase "ExStr passthrough" $ evalExpr emptyEnv (ExStr "hi") @?= VStr "hi"
    , testCase "ExNull yields VNull" $ evalExpr emptyEnv ExNull @?= VNull
    , testCase "malformed ExInt text falls back to VInt 0" $
        evalExpr emptyEnv (ExInt "not-a-number") @?= VInt 0
    ]

  , testGroup "evalExpr / variables"
    [ testCase "ExLvalue single segment looks up env" $
        let env = Map.fromList [("x_1", VInt 7)]
        in evalExpr env (ExLvalue (Lvalue [LvSegment "x_1" Nothing])) @?= VInt 7

    , testCase "ExLvalue missing var yields VNull" $
        evalExpr emptyEnv (ExLvalue (Lvalue [LvSegment "missing" Nothing])) @?= VNull

    , testCase "ExLvalue multi-segment falls back to VNull" $
        evalExpr emptyEnv (ExLvalue (Lvalue [LvSegment "obj" Nothing, LvSegment "field" Nothing])) @?= VNull
    ]

  , testGroup "evalExpr / operators"
    [ testCase "BopAdd on two VInt stays VInt" $
        evalExpr emptyEnv (ExBinOp (ExInt "2") BopAdd (ExInt "3")) @?= VInt 5

    , testCase "BopAdd promotes to VReal when either operand is VReal" $
        evalExpr emptyEnv (ExBinOp (ExInt "2") BopAdd (ExReal "0.5")) @?= VReal 2.5

    , testCase "BopSub on two VInt stays VInt" $
        evalExpr emptyEnv (ExBinOp (ExInt "5") BopSub (ExInt "3")) @?= VInt 2

    , testCase "BopMul on two VInt stays VInt" $
        evalExpr emptyEnv (ExBinOp (ExInt "4") BopMul (ExInt "3")) @?= VInt 12

    , testCase "BopDiv always yields VReal" $
        evalExpr emptyEnv (ExBinOp (ExInt "7") BopDiv (ExInt "2")) @?= VReal 3.5

    , testCase "BopEq on equal ints" $
        evalExpr emptyEnv (ExBinOp (ExInt "4") BopEq (ExInt "4")) @?= VBool True

    , testCase "BopNe on differing ints" $
        evalExpr emptyEnv (ExBinOp (ExInt "4") BopNe (ExInt "5")) @?= VBool True

    , testCase "BopLt on ints" $
        evalExpr emptyEnv (ExBinOp (ExInt "1") BopLt (ExInt "2")) @?= VBool True

    , testCase "BopGe on equal ints" $
        evalExpr emptyEnv (ExBinOp (ExInt "2") BopGe (ExInt "2")) @?= VBool True

    , testCase "BopAnd on two VBool" $
        evalExpr emptyEnv (ExBinOp (ExBool True) BopAnd (ExBool False)) @?= VBool False

    , testCase "BopOr on two VBool" $
        evalExpr emptyEnv (ExBinOp (ExBool True) BopOr (ExBool False)) @?= VBool True

    , testCase "BopXor on two VBool" $
        evalExpr emptyEnv (ExBinOp (ExBool True) BopXor (ExBool True)) @?= VBool False

    , testCase "ExNot negates VBool" $
        evalExpr emptyEnv (ExNot (ExBool True)) @?= VBool False

    , testCase "ExNeg negates VInt" $
        evalExpr emptyEnv (ExNeg (ExInt "5")) @?= VInt (-5)

    , testCase "ExNeg negates VReal" $
        evalExpr emptyEnv (ExNeg (ExReal "1.5")) @?= VReal (-1.5)
    ]

  , testGroup "evalExpr / non-pure shapes (documented fallback)"
    [ testCase "bare ExCall yields VNull placeholder" $
        evalExpr emptyEnv (ExCall (Lvalue [LvSegment "f" Nothing]) []) @?= VNull
    ]

  -- Plan 146 Phase 2k: 'Value's derived 'Eq' used IEEE754 'Double' equality,
  -- under which NaN /= NaN — so two independently compiled traces that both
  -- legitimately compute the same NaN (e.g. a 0.0/0.0 ratio) looked like a
  -- --dual-trace divergence when there was none. 'Value' now has a hand-written
  -- 'Eq' that treats NaN as equal to itself for this reason.
  , testGroup "Value Eq (Plan 146 Phase 2k: NaN compares equal to itself)"
    [ testCase "VReal NaN == VReal NaN" $
        VReal (0/0) @?= VReal (0/0)
    , testCase "VReal NaN /= VReal 1.0" $
        assertBool "NaN should not equal a real number" (VReal (0/0) /= VReal 1.0)
    , testCase "VReal 1.0 == VReal 1.0 still uses ordinary equality" $
        VReal 1.0 @?= VReal 1.0
    ]

  , testGroup "evalExprMocked / call-shaped Expr resolves via mock table (Plan 146 Phase 2a)"
    [ testCase "ExCall with no args hits the mock table" $
        let callExpr = ExCall (Lvalue [LvSegment "f" Nothing]) []
            mocks     = Map.fromList [(("f", []), VInt 99)] :: MockResponses
        in evalExprMocked mocks emptyEnv callExpr @?= VInt 99

    , testCase "ExMethodCall with no args hits the mock table, keyed by receiver.method" $
        let callExpr = ExMethodCall (ExLvalue (Lvalue [LvSegment "dw_1" Nothing])) "RowCount" []
            mocks     = Map.fromList [(("dw_1.RowCount", []), VInt 5)] :: MockResponses
        in evalExprMocked mocks emptyEnv callExpr @?= VInt 5

    , testCase "ExCall with evaluated args matches on the parsed argument values" $
        let callExpr = ExCall (Lvalue [LvSegment "f" Nothing]) [[mkTok TkIntLiteral "5"]]
            mocks     = Map.fromList [(("f", [VInt 5]), VStr "matched")] :: MockResponses
        in evalExprMocked mocks emptyEnv callExpr @?= VStr "matched"

    , testCase "ExCall args are evaluated against env before the mock lookup" $
        let callExpr = ExCall (Lvalue [LvSegment "f" Nothing]) [[mkTok TkIdent "x_1"]]
            env       = Map.fromList [("x_1", VInt 7)]
            mocks     = Map.fromList [(("f", [VInt 7]), VStr "matched")] :: MockResponses
        in evalExprMocked mocks env callExpr @?= VStr "matched"

    , testCase "a mock miss still falls back to VNull, not a crash" $
        let callExpr = ExCall (Lvalue [LvSegment "f" Nothing]) []
            mocks     = Map.fromList [(("g", []), VInt 1)] :: MockResponses
        in evalExprMocked mocks emptyEnv callExpr @?= VNull

    , testCase "a call nested inside a binop resolves via mocks, not just top-level calls" $
        let callExpr = ExBinOp (ExCall (Lvalue [LvSegment "f" Nothing]) []) BopAdd (ExInt "1")
            mocks     = Map.fromList [(("f", []), VInt 10)] :: MockResponses
        in evalExprMocked mocks emptyEnv callExpr @?= VInt 11

    , testCase "evalExpr (no-mocks entry point) still falls back to VNull even when a table would have matched elsewhere" $
        evalExpr emptyEnv (ExCall (Lvalue [LvSegment "f" Nothing]) []) @?= VNull
    ]
  ]
