module CpsCompileTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr         (Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Located      (Located (..))
import PB.Pipeline.CpsCompile

import Test.Tasty           (TestTree, testGroup)
import Test.Tasty.HUnit     (assertBool, testCase, (@?=))

-- Helpers

at :: Int -> a -> Located a
at n x = Located n x

lv1 :: Text -> Lvalue
lv1 n = Lvalue [LvSegment n Nothing]

-- Retrieve call: dw.retrieve()
retrieveCall :: Expr
retrieveCall =
  ExCall { callee = Lvalue [LvSegment "dw" Nothing, LvSegment "retrieve" Nothing]
         , callArgs = []
         }

-- open(w_test)
openCall :: Expr
openCall =
  ExCall { callee = Lvalue [LvSegment "open" Nothing]
         , callArgs = [["w_test"]]
         }

-- Pure call: messagebox("hi")
pureCall :: Expr
pureCall =
  ExCall { callee = Lvalue [LvSegment "messagebox" Nothing]
         , callArgs = [["\"hi\""]]
         }

tests :: TestTree
tests = testGroup "CpsCompile"

  [ testCase "empty body → single CpsReturn at entry 0" $ do
      let g = compileProcedure []
      cgEntry g @?= 0
      length (cgNodes g) @?= 1
      case cgNodes g of
        [CpsReturn Nothing] -> pure ()
        ns                  -> assertBool ("expected [CpsReturn Nothing], got: " <> show ns) False

  , testCase "single BsAssign → assign node + return, entry ≠ 0" $ do
      let stmt = at 10 (BsAssign (lv1 "x") (ExInt "1"))
          g    = compileProcedure [stmt]
      length (cgNodes g) @?= 2
      assertBool "entry should be > 0" (cgEntry g > 0)
      case cgNodes g of
        [CpsReturn {}, CpsAssign { anVar = "x" }] -> pure ()
        ns -> assertBool ("unexpected nodes: " <> show ns) False

  , testCase "BsCall retrieve → CpsSuspend with effect executeSql" $ do
      let stmt = at 5 (BsCall retrieveCall)
          g    = compileProcedure [stmt]
      let suNodes = [ n | n@CpsSuspend {} <- cgNodes g ]
      assertBool "expected at least one CpsSuspend" (not (null suNodes))
      case suNodes of
        (s:_) -> suEffect s @?= "executeSql"
        _     -> pure ()

  , testCase "BsCall retrieve → listed in suspensionPoints" $ do
      let stmt = at 5 (BsCall retrieveCall)
          g    = compileProcedure [stmt]
      assertBool "suspensionPoints should be non-empty" (not (null (cgSuspensionPoints g)))

  , testCase "BsCall open → CpsSuspend with effect open" $ do
      let stmt = at 7 (BsCall openCall)
          g    = compileProcedure [stmt]
      let suNodes = [ n | n@CpsSuspend {} <- cgNodes g ]
      assertBool "expected CpsSuspend" (not (null suNodes))
      case suNodes of
        (s:_) -> suEffect s @?= "open"
        _     -> pure ()

  , testCase "pure BsCall → CpsCall (not suspend)" $ do
      let stmt = at 3 (BsCall pureCall)
          g    = compileProcedure [stmt]
      let suNodes = [ n | n@CpsSuspend {} <- cgNodes g ]
      let caNodes = [ n | n@CpsCall {} <- cgNodes g ]
      suNodes @?= []
      assertBool "expected CpsCall" (not (null caNodes))

  , testCase "BsIf → CpsBranch node" $ do
      let thenS = [at 2 (BsAssign (lv1 "x") (ExInt "1"))]
          stmt  = at 1 (BsIf (IfStmt (ExBool True) thenS [] Nothing))
          g     = compileProcedure [stmt]
      let brNodes = [ n | n@CpsBranch {} <- cgNodes g ]
      assertBool "expected CpsBranch" (not (null brNodes))

  , testCase "BsAssign on line 42 → 42 appears in sourceMap" $ do
      let stmt = at 42 (BsAssign (lv1 "x") (ExInt "1"))
          g    = compileProcedure [stmt]
      let lines = map snd (cgSourceMap g)
      assertBool "line 42 should be in sourceMap" (42 `elem` lines)
  ]
