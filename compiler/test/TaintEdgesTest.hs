module TaintEdgesTest (tests) where

import PB.Prelude hiding (id, (.))
import qualified Prelude as P
import PB.AST.BodyStmt   (BodyStmt (..), IfStmt (..))
import PB.AST.Expr       (BinOp (..), Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Ident      (mkIdent)
import PB.AST.Located    (Located (..))
import PB.Compile.Flatten (compileProcedureToEff)
import PB.Analysis.TaintEdges (foldTaintEdgesEff)
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))

import qualified Control.Exception as CE
import           GHC.Conc          (getAllocationCounter, setAllocationCounter)
import           Data.Int          (Int64)
import           System.Timeout    (timeout)

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T
import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv Map.empty Map.empty Map.empty Map.empty "" Map.empty

measureAllocBytes :: IO a -> IO Int64
measureAllocBytes act = do
  setAllocationCounter maxBound
  _ <- act
  remaining <- getAllocationCounter
  pure (maxBound P.- remaining)

lvExpr :: Text -> Expr
lvExpr n = ExLvalue (Lvalue [LvSegment (mkIdent n) Nothing])

assignStmt :: Int -> Text -> Expr -> Located BodyStmt
assignStmt line lhs rhs = Located line (BsAssign (Lvalue [LvSegment (mkIdent lhs) Nothing]) rhs)

foldEdges :: [Located BodyStmt] -> Set.Set (Text, Text)
foldEdges body = foldTaintEdgesEff (compileProcedureToEff emptyEnv Set.empty body)

tests :: TestTree
tests = testGroup "TaintEdges"

  [ testGroup "foldTaintEdgesEff over EAssignWithRhs"
    [ testCase "simple def-use chain: y = x + 1 -> {(x,y)}" $
        foldEdges [assignStmt 1 "y" (ExBinOp (lvExpr "x") BopAdd (ExInt "1"))]
          @?= Set.singleton ("x", "y")

    , testCase "self-referencing assign excluded: x = x + 1 -> {}" $
        foldEdges [assignStmt 1 "x" (ExBinOp (lvExpr "x") BopAdd (ExInt "1"))]
          @?= Set.empty

    , testCase "two uses in one rhs both recorded: z = a + b -> {(a,z),(b,z)}" $
        foldEdges [assignStmt 1 "z" (ExBinOp (lvExpr "a") BopAdd (lvExpr "b"))]
          @?= Set.fromList [("a", "z"), ("b", "z")]

    , testCase "literal rhs with no identifiers yields no edges" $
        foldEdges [assignStmt 1 "x" (ExInt "1")] @?= Set.empty

    , testCase "chained assigns: y = x + 1; z = y + 1 -> {(x,y),(y,z)}" $
        foldEdges
          [ assignStmt 1 "y" (ExBinOp (lvExpr "x") BopAdd (ExInt "1"))
          , assignStmt 2 "z" (ExBinOp (lvExpr "y") BopAdd (ExInt "1"))
          ]
          @?= Set.fromList [("x", "y"), ("y", "z")]
    ]

  , testGroup "branch fan-in unions both arms' edges"
    [ testCase "if/else with different assigns in each arm" $
        let body =
              [ Located 1 (BsIf (IfStmt (ExBool True)
                  [assignStmt 2 "b" (lvExpr "a")] []
                  (Just [assignStmt 3 "d" (lvExpr "c")])))
              ]
        in foldEdges body @?= Set.fromList [("a", "b"), ("c", "d")]
    ]

  , testGroup "force-time memo: foldFreyd's own ELetRef cache is sufficient"
    [ testCase "18 sequential if/else groups: allocates < 20MB, not 2^18 blowup" $ do
        let group base =
              [ Located (base P.+ 1) (BsIf (IfStmt (ExBool True)
                  [assignStmt (base P.+ 2) ("b" <> T.pack (show base)) (lvExpr ("a" <> T.pack (show base)))] []
                  (Just [assignStmt (base P.+ 3) ("d" <> T.pack (show base)) (lvExpr ("c" <> T.pack (show base)))])))
              , assignStmt (base P.+ 4) ("tail" <> T.pack (show base)) (lvExpr ("src" <> T.pack (show base)))
              ]
            body = concatMap group [ n P.* 4 | n <- [0 .. 17 :: Int] ]
        mBytes <- timeout 30000000 (measureAllocBytes (CE.evaluate (Set.size (foldEdges body))))
        case mBytes of
          Nothing -> assertFailure "did not complete within the 30s hang-safety-net timeout"
          Just bytes -> assertBool
            ("allocated " <> show bytes <> " bytes; expected < 20MB (foldFreyd's ELetRef \
             \memo should keep this linear, not 2^18 re-forcing)")
            (bytes P.< 20 P.* 1000 P.* 1000)
    ]
  ]
