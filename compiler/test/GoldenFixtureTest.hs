-- | Plan 146 Phase 3 — hand-compiled golden fixtures.
--
-- Every prior Plan 146 test (Phase 1D, Phase 2a-k) validated the new compiler
-- against the /old/ compiler: "old and new agree" was strong evidence but not
-- proof, since a bug shared by both compilers would have been invisible to
-- that comparison. This module instead pins each fixture's expected
-- 'PB.Analysis.CatEval.TraceEvent' sequence and final environment to a value
-- derived by hand from PB's documented statement semantics (see
-- @doc/spec.md@ and each fixture's own comment) — independent of what the
-- compiler happens to produce — and then asserts that
-- 'PB.Analysis.CatOp.compileProcedureViaCatOp' matches it exactly. (The old
-- compiler, 'PB.Analysis.InstrGraph.compileProcedure', was deleted in Plan
-- 144 Phase 5 Step 7 once this and the dual-trace corpus run confirmed
-- equivalence; these fixtures no longer compare against it.)
--
-- Deliberately small and curated, not exhaustive (Phase 1/2's generated and
-- corpus-driven testing already cover broad syntax). Candidates are the
-- shapes named in @doc/plan/146-semantic-equivalence-oracle.md@'s own Phase
-- 3 section: if/if-else, nested if, choose-case with distinct per-clause
-- args, a for-loop and a do-while loop each containing one call, and a loop
-- containing an if/else with a shared tail (the 'compileLoopBody' defect
-- target). try/catch is intentionally excluded — see the BACKLOG entry filed
-- alongside this module for why.
module GoldenFixtureTest (tests) where

import PB.Prelude
import PB.AST.Expr         (BinOp (..), Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Type         ()
import PB.AST.BodyStmt     (BodyStmt (..), IfStmt (..), ForStmt (..), DoStmt (..), DoCondition (..),
                            ChooseStmt (..), CaseClause (..))
import PB.AST.Located      (Located (..))
import PB.Analysis.GraphBuilder (compileProcedureViaCatOp)
import PB.Analysis.CatEval (Value (..), TraceEvent (..))
import PB.Analysis.InstrInterp  (runInstrGraphTrace)
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.AST.Type         (PbType (..))
import PB.Lexing.Lexer     (tokenizeLine, LexLine (..))
import PB.Lexing.Token     (Token (..), TokenKind (..), SourceSpan (..))
import PB.Pipeline.Preprocess (LogicalLine (..))

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

-- | Environment with one datawindow-typed global — enough to make
-- @dw_foo.retrieve(...)@ classify as a suspend call, the same idiom
-- 'CatOpTest.hs's @dwEnv@ uses.
dwEnv :: ScopedTypeEnv
dwEnv = ScopedTypeEnv
  { steGlobal       = Map.fromList [("dw_foo", PtPrimitive "datawindow")]
  , steInstance     = Map.empty
  , steLocal        = Map.empty
  , steHierarchy    = Map.empty
  , steObject       = ""
  , steControlIndex = Map.empty
  }

emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv Map.empty Map.empty Map.empty Map.empty "" Map.empty

lv :: Text -> Lvalue
lv n = Lvalue [LvSegment n Nothing]

ex :: Text -> Expr
ex n = ExLvalue (lv n)

-- | Tokenize a source snippet into one real 'Token' (mirrors the identical
-- helper in 'CatOpTest.hs'/'InstrGraphTest.hs') — used to build genuine
-- @callArgs@ token lists (e.g. a bare identifier reference) rather than
-- hand-rolled fakes.
tok :: Text -> Token
tok t = case lexResult (tokenizeLine ll) of
  Right (tk:_) -> tk
  _            -> Token TkIdent t (SourceSpan 1 1 1)
  where ll = LogicalLine t 1 1

-- | @dw_foo.retrieve(argToks)@ as a standalone call statement.
retrieveCall :: [Token] -> BodyStmt
retrieveCall argToks = BsCall (ExCall (Lvalue [LvSegment "dw_foo" Nothing, LvSegment "retrieve" Nothing]) [argToks])

-- | Run one body through the compiler (bounded fuel — none of these
-- fixtures should ever need more than a few hundred steps; a fixture that
-- hits the bound has a bug, not a legitimately long trace) and return
-- @(finalEnv, trace)@ (outcome dropped — these fixtures always halt
-- naturally).
runNew :: ScopedTypeEnv -> [Located BodyStmt] -> Map.Map Text Value
       -> (Map.Map Text Value, [TraceEvent])
runNew env body initEnv =
  let maxSteps = 500 :: Int
      (ne, nt, _) = runInstrGraphTrace maxSteps Map.empty (compileProcedureViaCatOp env Set.empty body) initEnv
  in (ne, nt)

tests :: TestTree
tests = testGroup "Plan 146 Phase 3: hand-compiled golden fixtures"
  [ testGroup "if / if-else (Bug A family)"
    -- x = 0; if <cond> then x = 1 end if; y = 2
    [ testCase "if-true, no else: then-body runs, trailing statement runs" $
        let body = [ Located 1 (BsAssign (lv "x") (ExInt "0"))
                   , Located 2 (BsIf (IfStmt (ExBool True) [Located 3 (BsAssign (lv "x") (ExInt "1"))] [] Nothing))
                   , Located 4 (BsAssign (lv "y") (ExInt "2"))
                   ]
            expectedTrace = [TeAssign "x" (VInt 0), TeBranch True, TeAssign "x" (VInt 1), TeAssign "y" (VInt 2)]
            expectedEnv   = Map.fromList [("x", VInt 1), ("y", VInt 2)]
            (ne, nt) = runNew emptyEnv body Map.empty
        in (nt, ne) @?= (expectedTrace, expectedEnv)

    , testCase "if-false, no else: body skipped, trailing statement still runs" $
        let body = [ Located 1 (BsAssign (lv "x") (ExInt "0"))
                   , Located 2 (BsIf (IfStmt (ExBool False) [Located 3 (BsAssign (lv "x") (ExInt "1"))] [] Nothing))
                   , Located 4 (BsAssign (lv "y") (ExInt "2"))
                   ]
            expectedTrace = [TeAssign "x" (VInt 0), TeBranch False, TeAssign "y" (VInt 2)]
            expectedEnv   = Map.fromList [("x", VInt 0), ("y", VInt 2)]
            (ne, nt) = runNew emptyEnv body Map.empty
        in (nt, ne) @?= (expectedTrace, expectedEnv)

    , testCase "if/else, false condition: else-branch runs, trailing statement runs" $
        let body = [ Located 1 (BsAssign (lv "x") (ExInt "0"))
                   , Located 2 (BsIf (IfStmt (ExBool False) [Located 3 (BsAssign (lv "x") (ExInt "1"))] []
                                       (Just [Located 4 (BsAssign (lv "x") (ExInt "2"))])))
                   , Located 5 (BsAssign (lv "y") (ExInt "3"))
                   ]
            expectedTrace = [TeAssign "x" (VInt 0), TeBranch False, TeAssign "x" (VInt 2), TeAssign "y" (VInt 3)]
            expectedEnv   = Map.fromList [("x", VInt 2), ("y", VInt 3)]
            (ne, nt) = runNew emptyEnv body Map.empty
        in (nt, ne) @?= (expectedTrace, expectedEnv)
    ]

  , testGroup "nested if inside if/else (w_dw_functions::clicked shape)"
    -- if true then
    --   if <innerCond> then a = 1 else a = 2 end if
    --   b = 10
    --   c = 20
    -- end if
    [ let mkBody innerCond =
            [ Located 1 (BsIf (IfStmt (ExBool True)
                [ Located 2 (BsIf (IfStmt innerCond [Located 3 (BsAssign (lv "a") (ExInt "1"))] []
                                    (Just [Located 4 (BsAssign (lv "a") (ExInt "2"))])))
                , Located 5 (BsAssign (lv "b") (ExInt "10"))
                , Located 6 (BsAssign (lv "c") (ExInt "20"))
                ] [] Nothing))
            ]
      in testGroup "hand-derived trace for both reachable inner branches"
        [ testCase "outer true, inner true: inner then-arm plus shared trailing assigns" $
            let expectedTrace = [TeBranch True, TeBranch True, TeAssign "a" (VInt 1), TeAssign "b" (VInt 10), TeAssign "c" (VInt 20)]
                expectedEnv   = Map.fromList [("a", VInt 1), ("b", VInt 10), ("c", VInt 20)]
                (ne, nt) = runNew emptyEnv (mkBody (ExBool True)) Map.empty
            in (nt, ne) @?= (expectedTrace, expectedEnv)

        , testCase "outer true, inner false: inner else-arm plus shared trailing assigns" $
            let expectedTrace = [TeBranch True, TeBranch False, TeAssign "a" (VInt 2), TeAssign "b" (VInt 10), TeAssign "c" (VInt 20)]
                expectedEnv   = Map.fromList [("a", VInt 2), ("b", VInt 10), ("c", VInt 20)]
                (ne, nt) = runNew emptyEnv (mkBody (ExBool False)) Map.empty
            in (nt, ne) @?= (expectedTrace, expectedEnv)
        ]
    ]

  , testGroup "choose case, 3 clauses with distinct per-clause suspend args (Bug B family)"
    -- choose case sel
    --   case 1: dw_foo.retrieve(1)
    --   case 2: dw_foo.retrieve(2)
    --   case 3: dw_foo.retrieve(3)
    --   case else: dw_foo.retrieve(99)
    -- end choose
    --
    -- Compiles to a chain of equality tests in clause order (clause 1 tested
    -- first), so the expected trace is exactly the "test each case value in
    -- program order until one matches" reading of the source — a person
    -- tracing this by hand would derive the same TeBranch/TeSuspend
    -- sequence without needing to know anything about how the compiler
    -- internally represents an N-way dispatch.
    [ let clauses = [ CaseClause (Just [tok "1"]) [Located 2 (retrieveCall [tok "1"])]
                     , CaseClause (Just [tok "2"]) [Located 3 (retrieveCall [tok "2"])]
                     , CaseClause (Just [tok "3"]) [Located 4 (retrieveCall [tok "3"])]
                     , CaseClause Nothing          [Located 5 (retrieveCall [tok "99"])]
                     ]
          body = [Located 1 (BsChoose (ChooseStmt (ex "sel") clauses))]
          runSel n = runNew dwEnv body (Map.fromList [("sel", VInt n)])
      in testGroup "dispatches to the matching clause's own suspend call"
        [ testCase "clause 1 selected" $
            let expectedTrace = [TeBranch True, TeSuspend "retrieve:dw_foo" [VInt 1]]
                (ne, nt) = runSel 1
            in (nt, ne) @?= (expectedTrace, Map.fromList [("sel", VInt 1)])

        , testCase "clause 2 selected" $
            let expectedTrace = [TeBranch False, TeBranch True, TeSuspend "retrieve:dw_foo" [VInt 2]]
                (ne, nt) = runSel 2
            in (nt, ne) @?= (expectedTrace, Map.fromList [("sel", VInt 2)])

        , testCase "clause 3 selected" $
            let expectedTrace = [TeBranch False, TeBranch False, TeBranch True, TeSuspend "retrieve:dw_foo" [VInt 3]]
                (ne, nt) = runSel 3
            in (nt, ne) @?= (expectedTrace, Map.fromList [("sel", VInt 3)])

        , testCase "no clause matches: falls through to case-else's own suspend call" $
            let expectedTrace = [TeBranch False, TeBranch False, TeBranch False, TeSuspend "retrieve:dw_foo" [VInt 99]]
                (ne, nt) = runSel 42
            in (nt, ne) @?= (expectedTrace, Map.fromList [("sel", VInt 42)])
        ]
    ]

  , testGroup "for loop containing one call"
    -- for i = 1 to 3
    --   dw_foo.retrieve(i)
    -- next
    --
    -- PB's for-next tests "i <= to" before every iteration (including the
    -- first), runs the body, then increments by step (default 1) — so this
    -- must produce exactly 3 calls, with i = 1, 2, 3 in that order, and i
    -- left at 4 (one past the bound) once the loop exits.
    [ testCase "iterates i = 1..3, one suspend call per iteration with i as its argument" $
        let body = [Located 1 (BsFor (ForStmt (lv "i") (ExInt "1") (ExInt "3") Nothing
                     [Located 2 (retrieveCall [tok "i"])]))]
            expectedTrace =
              [ TeAssign "i" (VInt 1), TeBranch True, TeSuspend "retrieve:dw_foo" [VInt 1]
              , TeAssign "i" (VInt 2), TeBranch True, TeSuspend "retrieve:dw_foo" [VInt 2]
              , TeAssign "i" (VInt 3), TeBranch True, TeSuspend "retrieve:dw_foo" [VInt 3]
              , TeAssign "i" (VInt 4), TeBranch False
              ]
            expectedEnv = Map.fromList [("i", VInt 4)]
            (ne, nt) = runNew dwEnv body Map.empty
        in (nt, ne) @?= (expectedTrace, expectedEnv)
    ]

  , testGroup "do-while loop containing one call"
    -- i = 1
    -- do while i <= 3
    --   dw_foo.retrieve(i)
    --   i = i + 1
    -- loop
    --
    -- Top-tested: same "test before every iteration" semantics as for-next,
    -- with the increment written explicitly rather than implicit — so the
    -- hand-derived trace is identical in shape to the for-loop fixture
    -- above (same 3 calls, same final i = 4).
    [ testCase "iterates i = 1..3, one suspend call per iteration with i as its argument" $
        let body = [ Located 1 (BsAssign (lv "i") (ExInt "1"))
                   , Located 2 (BsDo (DoStmt (Just (DoWhile (ExBinOp (ex "i") BopLe (ExInt "3"))))
                       [ Located 3 (retrieveCall [tok "i"])
                       , Located 4 (BsAssign (lv "i") (ExBinOp (ex "i") BopAdd (ExInt "1")))
                       ] Nothing))
                   ]
            expectedTrace =
              [ TeAssign "i" (VInt 1)
              , TeBranch True, TeSuspend "retrieve:dw_foo" [VInt 1], TeAssign "i" (VInt 2)
              , TeBranch True, TeSuspend "retrieve:dw_foo" [VInt 2], TeAssign "i" (VInt 3)
              , TeBranch True, TeSuspend "retrieve:dw_foo" [VInt 3], TeAssign "i" (VInt 4)
              , TeBranch False
              ]
            expectedEnv = Map.fromList [("i", VInt 4)]
            (ne, nt) = runNew dwEnv body Map.empty
        in (nt, ne) @?= (expectedTrace, expectedEnv)
    ]

  , testGroup "loop containing if/else with a shared tail (compileLoopBody defect target)"
    -- iter = 0
    -- y = 0
    -- do while iter < 2
    --   iter = iter + 1
    --   if iter == 1 then dw_foo.retrieve(1) else dw_foo.retrieve(2) end if
    --   y = y + 1
    -- loop
    --
    -- "y = y + 1" is reached from both the then-arm and the else-arm on
    -- every iteration — the AST-level counterpart to the SSA-level fixture
    -- in CatOpTest.hs's "compileLoopBody" group (Plan 146 item 7), here run
    -- through the real BodyStmt->CFG->SSA pipeline instead of a hand-built
    -- SsaProc, with a fully hand-derived trace rather than just a
    -- final-value check.
    [ testCase "shared tail (y += 1) fires on every iteration regardless of which branch is taken" $
        let body = [ Located 1 (BsAssign (lv "iter") (ExInt "0"))
                   , Located 2 (BsAssign (lv "y") (ExInt "0"))
                   , Located 3 (BsDo (DoStmt (Just (DoWhile (ExBinOp (ex "iter") BopLt (ExInt "2"))))
                       [ Located 4 (BsAssign (lv "iter") (ExBinOp (ex "iter") BopAdd (ExInt "1")))
                       , Located 5 (BsIf (IfStmt (ExBinOp (ex "iter") BopEq (ExInt "1"))
                           [Located 6 (retrieveCall [tok "1"])] []
                           (Just [Located 7 (retrieveCall [tok "2"])])))
                       , Located 8 (BsAssign (lv "y") (ExBinOp (ex "y") BopAdd (ExInt "1")))
                       ] Nothing))
                   ]
            expectedTrace =
              [ TeAssign "iter" (VInt 0), TeAssign "y" (VInt 0)
              , TeBranch True
              , TeAssign "iter" (VInt 1), TeBranch True, TeSuspend "retrieve:dw_foo" [VInt 1], TeAssign "y" (VInt 1)
              , TeBranch True
              , TeAssign "iter" (VInt 2), TeBranch False, TeSuspend "retrieve:dw_foo" [VInt 2], TeAssign "y" (VInt 2)
              , TeBranch False
              ]
            expectedEnv = Map.fromList [("iter", VInt 2), ("y", VInt 2)]
            (ne, nt) = runNew dwEnv body Map.empty
        in (nt, ne) @?= (expectedTrace, expectedEnv)
    ]
  ]
