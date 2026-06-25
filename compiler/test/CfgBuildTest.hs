module CfgBuildTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr         (Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Located      (Located (..))
import PB.Analysis.CfgBuild

import Test.Tasty           (TestTree, testGroup)
import Test.Tasty.HUnit     (assertBool, testCase, (@?=))

-- Helper to build a Located with a dummy line number.
at :: Int -> a -> Located a
at n x = Located n x

-- A minimal lvalue with one segment.
lv1 :: Text -> Lvalue
lv1 n = Lvalue [LvSegment n Nothing]

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

  , testCase "BsReturn → block added to cfgExits" $ do
      let stmt = at 1 (BsReturn Nothing)
          g    = buildCfg [stmt]
      length (cfgExits g) @?= 1
  ]
