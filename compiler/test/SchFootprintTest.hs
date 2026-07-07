module SchFootprintTest (tests) where

import PB.Prelude hiding (id, (.))
import PB.AST.Expr           (Expr (..))
import PB.Analysis.CatOp     (Category (..), Cartesian (..), Cocartesian (..),
                               CatOp (..), branch)
import PB.Analysis.CatEval   (Value)
import PB.Analysis.SchFootprint
import PB.Analysis.SchemaCategory (SchMorphism (..), SchObject (..), StmtId (..), LegKind (..), FkSource (..))
import PB.Analysis.TypeEnv   (ScopedTypeEnv (..))
import PB.Pipeline.SqlParse  (TableRef (..))

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set

import Hedgehog             (forAll, property, (===), Gen)
import qualified Hedgehog.Gen   as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty           (TestTree, testGroup)
import Test.Tasty.HUnit     (testCase, (@?=))
import Test.Tasty.Hedgehog  (testProperty)

-- ---------------------------------------------------------------------------
-- Fixtures

emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv Map.empty Map.empty Map.empty Map.empty

ctx0 :: FunctorCtx
ctx0 = FunctorCtx
  { fcStmtObj   = SqlStmtId "f.srf" "obj" "proc" 1
  , fcTypeEnv   = emptyEnv
  , fcDwColumns = Map.empty
  }

-- Content is arbitrary: only used to exercise Set union as a monoid.
morphismA, morphismB, morphismC, morphismD, morphismE :: SchMorphism
morphismA = SchMorphism (ColumnObj (TableRef Nothing "t1") "a") (StmtObj (SqlStmtId "f" "o" "p" 1)) LegReads
morphismB = SchMorphism (StmtObj (SqlStmtId "f" "o" "p" 2)) (ColumnObj (TableRef Nothing "t2") "b") LegWrites
morphismC = SchMorphism (StmtObj (DwRetrieveId "f" "dw1")) (ColumnObj (TableRef Nothing "t3") "c") LegRetrieve
morphismD = SchMorphism (ColumnObj (TableRef Nothing "t4") "d") (ColumnObj (TableRef Nothing "t5") "e") (LegFk FkDdl)
morphismE = SchMorphism (ColumnObj (TableRef Nothing "t6") "f") (ColumnObj (TableRef Nothing "t7") "g") (LegFk FkDwJoin)

allMorphisms :: [SchMorphism]
allMorphisms = [morphismA, morphismB, morphismC, morphismD, morphismE]

genFootprintSet :: Gen (Set.Set SchMorphism)
genFootprintSet = Set.fromList <$> Gen.list (Range.linear 0 5) (Gen.element allMorphisms)

tests :: TestTree
tests = testGroup "SchFootprint"

  [ testGroup "category laws"
    [ testCase "id is the empty footprint" $
        runSchFootprint (id :: SchFootprint () ()) ctx0 @?= Set.empty

    , testCase "composition of two constant footprints unions them" $
        let f = SchFootprint (const (Set.fromList [morphismA])) :: SchFootprint () ()
            g = SchFootprint (const (Set.fromList [morphismB])) :: SchFootprint () ()
        in runSchFootprint (f . g) ctx0 @?= Set.fromList [morphismA, morphismB]

    , testCase "(&&&) unions both sides' footprints" $
        let f = SchFootprint (const (Set.fromList [morphismA])) :: SchFootprint () ()
            g = SchFootprint (const (Set.fromList [morphismB])) :: SchFootprint () ()
        in runSchFootprint (f &&& g) ctx0 @?= Set.fromList [morphismA, morphismB]

    , testCase "(|||) unions both branches' footprints (static over-approximation)" $
        let f = SchFootprint (const (Set.fromList [morphismA])) :: SchFootprint () ()
            g = SchFootprint (const (Set.fromList [morphismB])) :: SchFootprint () ()
        in runSchFootprint (f ||| g) ctx0 @?= Set.fromList [morphismA, morphismB]

    , testProperty "composition unions footprints associatively (Hedgehog)" $ property $ do
        sA <- forAll genFootprintSet
        sB <- forAll genFootprintSet
        sC <- forAll genFootprintSet
        let f = SchFootprint (const sA) :: SchFootprint () ()
            g = SchFootprint (const sB) :: SchFootprint () ()
            h = SchFootprint (const sC) :: SchFootprint () ()
        runSchFootprint ((f . g) . h) ctx0 === runSchFootprint (f . (g . h)) ctx0
        runSchFootprint (f . g) ctx0 === Set.union sA sB
    ]

  , testGroup "foldSchFootprint over CatOp (infra slice: always empty)"
    -- Every Effectful method is a constant empty footprint this session
    -- (Plan 148 Phase 3 infra slice) -- these are the completeness check
    -- that foldCat's generic dispatch reaches every one of CatOp's 20
    -- constructors without falling over, not a check of any real morphism
    -- detection (that lands in a follow-up session).
    [ testCase "CatId / CatCompose / CatAssignWithRhs" $
        foldSchFootprint ctx0 (CatAssignWithRhs "x" (ExInt "1") . CatId :: CatOp () ()) @?= Set.empty

    , testCase "branch: CatFanIn / CatSplitValue / CatFork / CatEval / CatCall / CatSuspend" $
        foldSchFootprint ctx0
          (branch (ExBool True) (CatCall "f" []) (CatSuspend "retrieve:dw" []) :: CatOp () ())
          @?= Set.empty

    , testCase "CatExl / CatExr" $ do
        foldSchFootprint ctx0 (CatExl :: CatOp ((), ()) ()) @?= Set.empty
        foldSchFootprint ctx0 (CatExr :: CatOp ((), ()) ()) @?= Set.empty

    , testCase "CatInl / CatInr" $ do
        foldSchFootprint ctx0 (CatInl :: CatOp () (Either () ())) @?= Set.empty
        foldSchFootprint ctx0 (CatInr :: CatOp () (Either () ())) @?= Set.empty

    , testCase "CatAssign / CatLookup" $ do
        foldSchFootprint ctx0 (CatAssign "x" :: CatOp ((), Value) ()) @?= Set.empty
        foldSchFootprint ctx0 (CatLookup "x" :: CatOp () Value) @?= Set.empty

    , testCase "CatReturn" $
        foldSchFootprint ctx0 (CatReturn :: CatOp () ()) @?= Set.empty

    , testCase "CatLoop (immediate break)" $
        foldSchFootprint ctx0 (CatLoop (CatInr :: CatOp () (Either () ())) :: CatOp () ()) @?= Set.empty

    , testCase "CatTry" $
        foldSchFootprint ctx0 (CatTry CatId (CatAssign "x") :: CatOp () ()) @?= Set.empty

    , testCase "CatTagged" $
        foldSchFootprint ctx0 (CatTagged "blk" CatId :: CatOp () ()) @?= Set.empty

    , testCase "CatConst" $
        foldSchFootprint ctx0 (CatConst (ExInt "1") :: CatOp () Value) @?= Set.empty
    ]
  ]
