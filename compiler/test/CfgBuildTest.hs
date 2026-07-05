module CfgBuildTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr         (Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Located      (Located (..))
import PB.Analysis.CfgBuild
import PB.Lexing.Token     (Token (..), TokenKind (..), SourceSpan (..))

import Test.Tasty           (TestTree, testGroup)
import Test.Tasty.HUnit     (assertBool, testCase, (@?=))

-- Helper to build a Located with a dummy line number.
at :: Int -> a -> Located a
at n x = Located n x

-- A minimal lvalue with one segment.
lv1 :: Text -> Lvalue
lv1 n = Lvalue [LvSegment n Nothing]

-- A minimal int-literal token for case-clause values.
tok :: Text -> Token
tok t = Token TkIntLiteral t (SourceSpan 1 1 1)

tests :: TestTree
tests = testGroup "CfgBuild"
  [ testCase "empty body → single entry block, no exits, no edges" $ do
      let g = buildCfg []
      length (cfgBlocks g) @?= 1
      cfgExits g         @?= []
      cfgEdges g         @?= []

  , testCase "single BsAssign → placed in entry block, no exits" $ do
      let stmt = at 1 (BsAssign (lv1 "x") (ExInt "1"))
          g    = buildCfg [stmt]
      length (cfgBlocks g) @?= 1
      case cfgBlocks g of
        (b0:_) -> length (cbStmts b0) @?= 1
        []     -> assertBool "expected at least one block" False
      cfgExits g          @?= []
      cfgEdges g          @?= []

  , testCase "BsIf → T/F edges plus merge block" $ do
      let thenS = [at 2 (BsAssign (lv1 "x") (ExInt "1"))]
          stmt  = at 1 (BsIf (IfStmt (ExBool True) thenS [] Nothing))
          g     = buildCfg [stmt]
      -- entry, then-entry, merge, plus T edge from entry → then, F edge entry → merge
      let edgeLabels = map ceLabel (cfgEdges g)
      elem "T" edgeLabels @?= True
      elem "F" edgeLabels @?= True
      length (cfgBlocks g) @?= 3

  , testCase "BsFor → cond block, body block, post block, loop back edge" $ do
      let bodyS = [at 2 (BsAssign (lv1 "x") (ExInt "0"))]
          stmt  = at 1 (BsFor (ForStmt (lv1 "i") (ExInt "1") (ExInt "10") Nothing bodyS))
          g     = buildCfg [stmt]
      let edgeLabels = map ceLabel (cfgEdges g)
      elem "T" edgeLabels   @?= True
      elem "F" edgeLabels   @?= True
      elem "loop" edgeLabels @?= True

  , testGroup "BsDo bottom-tested (Plan 146 Phase 2e: missing back-edge)"
    -- lowerDo's bottom-condition branch used to emit a single unconditional
    -- edge straight from the body's exit to the merge block (mislabeled
    -- "loop"), with no condition-test block and no back-edge at all — the
    -- loop body ran exactly once, no matter what the condition evaluated to.
    [ testCase "DO ... LOOP UNTIL → real T/F branch edges (not just an unconditional exit)" $ do
        let bodyS = [at 2 (BsAssign (lv1 "x") (ExInt "0"))]
            stmt  = at 1 (BsDo (DoStmt Nothing bodyS (Just (DoUntil (ExBool True)))))
            g     = buildCfg [stmt]
            edgeLabels = map ceLabel (cfgEdges g)
        assertBool ("expected a \"T\" edge (back to the loop body), got labels: " <> show edgeLabels)
          (elem "T" edgeLabels)
        assertBool ("expected an \"F\" edge (exit to merge), got labels: " <> show edgeLabels)
          (elem "F" edgeLabels)

    , testCase "DO ... LOOP WHILE → same T/F branch shape as UNTIL" $ do
        let bodyS = [at 2 (BsAssign (lv1 "x") (ExInt "0"))]
            stmt  = at 1 (BsDo (DoStmt Nothing bodyS (Just (DoWhile (ExBool True)))))
            g     = buildCfg [stmt]
            edgeLabels = map ceLabel (cfgEdges g)
        elem "T" edgeLabels @?= True
        elem "F" edgeLabels @?= True
    ]

  , testCase "BsReturn → block added to cfgExits" $ do
      let stmt = at 1 (BsReturn Nothing)
          g    = buildCfg [stmt]
      length (cfgExits g) @?= 1

  , testGroup "BsChoose (Plan 146 Bug B: default-edge gap)"
    [ testCase "no case-else clause → explicit \"default\" edge from header to merge block" $ do
        let clauses = [ CaseClause (Just [tok "1"]) [at 2 (BsAssign (lv1 "x") (ExInt "1"))]
                      , CaseClause (Just [tok "2"]) [at 3 (BsAssign (lv1 "x") (ExInt "2"))]
                      ]
            stmt = at 1 (BsChoose (ChooseStmt (ExLvalue (lv1 "y")) clauses))
            g    = buildCfg [stmt]
            edgeLabels = map ceLabel (cfgEdges g)
        assertBool ("expected a \"default\" edge, got labels: " <> show edgeLabels)
          (elem "default" edgeLabels)

    , testCase "case-else clause present → no synthetic \"default\" edge" $ do
        let clauses = [ CaseClause (Just [tok "1"]) [at 2 (BsAssign (lv1 "x") (ExInt "1"))]
                      , CaseClause Nothing          [at 3 (BsAssign (lv1 "x") (ExInt "2"))]
                      ]
            stmt = at 1 (BsChoose (ChooseStmt (ExLvalue (lv1 "y")) clauses))
            g    = buildCfg [stmt]
            edgeLabels = map ceLabel (cfgEdges g)
        assertBool ("expected no \"default\" edge, got labels: " <> show edgeLabels)
          (notElem "default" edgeLabels)
    ]
  ]
