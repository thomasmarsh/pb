module InterpCoverageTest (tests) where

import PB.Prelude
import PB.AST.Expr (BinOp (..), Expr (..), Lvalue (..), LvSegment (..))
import PB.AST.Ident (mkIdent)
import PB.AST.Located (Located (..))
import PB.AST.BodyStmt
  ( BodyStmt (..), IfStmt (..), ElseIf (..), ForStmt (..), DoStmt (..)
  , DoCondition (..), ChooseStmt (..), CaseClause (..)
  )
import PB.Lexing.Lexer     (tokenizeLine, LexLine (..))
import PB.Lexing.Token     (Token (..), TokenKind (..), SourceSpan (..))
import PB.Pipeline.Preprocess (mkLogicalLine)
import PB.Analysis.InterpCoverage
  ( SiteKind (..)
  , ExprCoverage (..)
  , CoverageSite (..)
  , CoverageSummary (..)
  , classifyExprCoverage
  , collectCoverage
  , summarizeCoverage
  , summarizeCoverageByKind
  )

import qualified Data.Map.Strict as Map
import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase, (@?=))

-- | A bare, unsubscripted single-segment lvalue -- the one 'ExLvalue' shape
-- 'evalExprMocked' resolves without a mock.
bareVar :: Text -> Expr
bareVar n = ExLvalue (Lvalue [LvSegment (mkIdent n) Nothing])

call :: Text -> Expr
call n = ExCall (Lvalue [LvSegment (mkIdent n) Nothing]) []

mkLv :: Text -> Lvalue
mkLv n = Lvalue [LvSegment (mkIdent n) Nothing]

loc :: BodyStmt -> Located BodyStmt
loc = Located 1

-- | Tokenize a single source snippet into one 'Token' via the real lexer
-- (mirrors 'EffTermTest.hs's identical helper) -- used to build genuine
-- call-argument token lists.
-- | Real-lex a single value for its correct TokenKind, then normalize its
-- span to a constant dummy -- callers compare against hand-built ASTs that
-- carry the same dummy span, not a real per-character position.
tok :: Text -> Token
tok t = case lexResult (tokenizeLine ll) of
  Right (tk:_) -> tk { tkSpan = SourceSpan 1 1 1 1 }
  _            -> Token TkIdent t (SourceSpan 1 1 1 1)
  where ll = mkLogicalLine t 1

tests :: TestTree
tests = testGroup "InterpCoverage"
  [ testGroup "classifyExprCoverage"
    [ testCase "ExBool literal is fully modeled" $
        classifyExprCoverage (ExBool True) @?= FullyModeled
    , testCase "ExInt literal is fully modeled" $
        classifyExprCoverage (ExInt "1") @?= FullyModeled
    , testCase "ExStr literal is fully modeled" $
        classifyExprCoverage (ExStr "x") @?= FullyModeled
    , testCase "ExNull is fully modeled (a real null, not a fallback)" $
        classifyExprCoverage ExNull @?= FullyModeled
    , testCase "bare single-segment variable read is fully modeled" $
        classifyExprCoverage (bareVar "li_x") @?= FullyModeled
    , testCase "multi-segment lvalue is structurally unmodeled" $
        classifyExprCoverage (ExLvalue (Lvalue [LvSegment "a" Nothing, LvSegment "b" Nothing]))
          @?= StructurallyUnmodeled
    , testCase "subscripted lvalue is structurally unmodeled" $
        classifyExprCoverage (ExLvalue (Lvalue [LvSegment "a" (Just ["1"])]))
          @?= StructurallyUnmodeled
    , testCase "ExCall is needs-mock" $
        classifyExprCoverage (call "f") @?= NeedsMock
    , testCase "ExMethodCall is needs-mock" $
        classifyExprCoverage (ExMethodCall (bareVar "dw_1") "Retrieve" []) @?= NeedsMock
    , testCase "ExArray is structurally unmodeled" $
        classifyExprCoverage (ExArray []) @?= StructurallyUnmodeled
    , testCase "ExHostVar is structurally unmodeled" $
        classifyExprCoverage (ExHostVar (Lvalue [LvSegment "x" Nothing])) @?= StructurallyUnmodeled
    , testCase "ExRaw is structurally unmodeled" $
        classifyExprCoverage (ExRaw ["select 1"]) @?= StructurallyUnmodeled
    , testCase "ExCreate is structurally unmodeled" $
        classifyExprCoverage (ExCreate "Foo") @?= StructurallyUnmodeled
    , testCase "ExBinOp of two fully-modeled operands is fully modeled" $
        classifyExprCoverage (ExBinOp (ExInt "1") BopAdd (ExInt "2")) @?= FullyModeled
    , testCase "ExBinOp with one needs-mock operand is needs-mock" $
        classifyExprCoverage (ExBinOp (call "f") BopAdd (ExInt "2")) @?= NeedsMock
    , testCase "ExBinOp with one structurally-unmodeled operand wins over needs-mock" $
        classifyExprCoverage (ExBinOp (ExArray []) BopAdd (call "f")) @?= StructurallyUnmodeled
    , testCase "ExNot propagates its operand's classification" $
        classifyExprCoverage (ExNot (call "f")) @?= NeedsMock
    , testCase "ExNeg propagates its operand's classification" $
        classifyExprCoverage (ExNeg (ExArray [])) @?= StructurallyUnmodeled
    ]
  , testGroup "collectCoverage"
    [ testCase "BsAssign records one AssignRhs site" $
        collectCoverage [loc (BsAssign (mkLv "x") (ExInt "1"))]
          @?= [CoverageSite AssignRhs FullyModeled]
    , testCase "BsAssign with an unmodeled RHS" $
        collectCoverage [loc (BsAssign (mkLv "x") (ExArray []))]
          @?= [CoverageSite AssignRhs StructurallyUnmodeled]
    , testCase "BsCall records one CallArg site per argument" $
        collectCoverage [loc (BsCall (ExCall (mkLv "proc") [ExInt "1", ExCall (mkLv "g") []]))]
          @?= [CoverageSite CallArg FullyModeled, CoverageSite CallArg NeedsMock]
    , testCase "BsIf records a BranchCond site plus both arms' sites, no replication" $
        collectCoverage
          [ loc (BsIf (IfStmt (call "check")
                   [loc (BsAssign (mkLv "then_var") (ExInt "1"))]
                   []
                   (Just [loc (BsAssign (mkLv "else_var") (ExInt "2"))])))
          ]
          @?= [ CoverageSite BranchCond NeedsMock
              , CoverageSite AssignRhs FullyModeled
              , CoverageSite AssignRhs FullyModeled
              ]
    , testCase "BsIf elseifs each record their own BranchCond site" $
        collectCoverage
          [ loc (BsIf (IfStmt (ExBool True) []
                   [ElseIf (call "f") [loc (BsAssign (mkLv "y") (ExInt "1"))]]
                   Nothing))
          ]
          @?= [CoverageSite BranchCond FullyModeled, CoverageSite BranchCond NeedsMock, CoverageSite AssignRhs FullyModeled]
    , testCase "BsDo records a BranchCond site for its while/until condition" $
        collectCoverage [loc (BsDo (DoStmt (Just (DoWhile (call "more"))) [] Nothing))]
          @?= [CoverageSite BranchCond NeedsMock]
    , testCase "BsChoose records a BranchCond site plus each clause's sites" $
        collectCoverage
          [ loc (BsChoose (ChooseStmt (bareVar "li_x")
                   [ CaseClause (Just [tok "1"]) [loc (BsAssign (mkLv "y") (ExArray []))]
                   , CaseClause Nothing [loc (BsAssign (mkLv "z") (ExInt "1"))]
                   ]))
          ]
          @?= [ CoverageSite BranchCond FullyModeled
              , CoverageSite AssignRhs StructurallyUnmodeled
              , CoverageSite AssignRhs FullyModeled
              ]
    , testCase "BsFor records sites for from/to/step bounds" $
        collectCoverage [loc (BsFor (ForStmt (mkLv "i") (ExInt "1") (call "n") (Just (ExInt "2")) []))]
          @?= [CoverageSite AssignRhs FullyModeled, CoverageSite AssignRhs NeedsMock, CoverageSite AssignRhs FullyModeled]
    , testCase "BsReturn records an AssignRhs site for its value" $
        collectCoverage [loc (BsReturn (Just (call "f")))] @?= [CoverageSite AssignRhs NeedsMock]
    , testCase "BsReturn with no value records nothing" $
        collectCoverage [loc (BsReturn Nothing)] @?= []
    , testCase "BsExit records nothing" $
        collectCoverage [loc BsExit] @?= []
    , testCase "a shared-looking body reached from two different if-arms is NOT replicated" $
        -- Regression for the EffTerm-fold design this module replaced: two
        -- textually-identical arms are two distinct AST nodes, each
        -- contributing its own site once.
        let arm = [loc (BsAssign (mkLv "y") (call "g"))]
        in collectCoverage [loc (BsIf (IfStmt (ExBool True) arm [] (Just arm)))]
             @?= [ CoverageSite BranchCond FullyModeled
                 , CoverageSite AssignRhs NeedsMock
                 , CoverageSite AssignRhs NeedsMock
                 ]
    ]
  , testGroup "summarizeCoverage"
    [ testCase "counts each bucket" $
        let sites = [ CoverageSite BranchCond FullyModeled
                    , CoverageSite CallArg NeedsMock
                    , CoverageSite CallArg NeedsMock
                    , CoverageSite AssignRhs StructurallyUnmodeled
                    ]
        in summarizeCoverage sites @?= CoverageSummary
             { csvTotal = 4, csvFullyModeled = 1, csvNeedsMock = 2, csvStructurallyUnmodeled = 1 }
    , testCase "empty input summarizes to all zeros" $
        summarizeCoverage [] @?= CoverageSummary 0 0 0 0
    ]
  , testGroup "summarizeCoverageByKind"
    [ testCase "groups sites by SiteKind before summarizing" $
        let sites = [ CoverageSite BranchCond FullyModeled
                    , CoverageSite CallArg NeedsMock
                    , CoverageSite CallArg StructurallyUnmodeled
                    ]
            byKind = summarizeCoverageByKind sites
        in do
          assertEqual "BranchCond bucket" (Just (CoverageSummary 1 1 0 0)) (Map.lookup BranchCond byKind)
          assertEqual "CallArg bucket" (Just (CoverageSummary 2 0 1 1)) (Map.lookup CallArg byKind)
          assertEqual "AssignRhs bucket absent" Nothing (Map.lookup AssignRhs byKind)
    ]
  ]
