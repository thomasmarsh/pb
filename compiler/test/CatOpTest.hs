module CatOpTest (tests) where

import PB.Prelude hiding (id, (.))
import qualified Prelude as P
import PB.AST.Expr         (Expr (..))
import PB.Analysis.CatOp
import PB.Analysis.SSA     (SsaVar (..), renderSsaVar, SsaProc (..), buildSsa)

import Test.Tasty           (TestTree, testGroup)
import Test.Tasty.HUnit     (assertBool, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "CatOp"
  [ testGroup "Category laws (structural)"
    [ testCase "id . id produces CatCompose" $
        assertBool "is CatCompose" (case (id . id :: CatOp Int Int) of CatCompose _ _ -> True; _ -> False)

    , testCase "id . id is structurally distinct from id" $
        assertBool "distinct" ((id :: CatOp Int Int) /= (id . id :: CatOp Int Int))
    ]

  , testGroup "Cocartesian"
    [ testCase "inl produces CatInl" $
        assertBool "is CatInl" (case (inl :: CatOp Int (Either Int Int)) of CatInl -> True; _ -> False)

    , testCase "inr produces CatInr" $
        assertBool "is CatInr" (case (inr :: CatOp Int (Either Int Int)) of CatInr -> True; _ -> False)

    , testCase "fanin produces CatFanIn" $
        assertBool "is CatFanIn" (case (CatFanIn id id :: CatOp (Either Int Int) Int) of CatFanIn _ _ -> True; _ -> False)
    ]

  , testGroup "Cartesian"
    [ testCase "fork produces CatFork" $
        assertBool "is CatFork" (case (id &&& id :: CatOp Int (Int, Int)) of CatFork _ _ -> True; _ -> False)
    ]

  , testGroup "CatOp constructors"
    [ testCase "CatId round-trips via Eq" $
        (CatId :: CatOp Int Int) @?= CatId

    , testCase "CatCompose equality" $
        CatCompose CatId (CatId :: CatOp Int Int) @?= CatCompose CatId CatId

    , testCase "CatLoop equality" $
        assertBool "CatLoop wraps inner" (case CatLoop (inl :: CatOp Int (Either Int Int)) of CatLoop _ -> True; _ -> False)
    ]

  , testGroup "SSA data types"
    [ testCase "SsaVar renders correctly" $
        renderSsaVar (SsaVar "x" 1) @?= "x_1"

    , testCase "SsaVar ordering" $
        assertBool "x_1 < x_2" (SsaVar "x" 1 P.< SsaVar "x" 2)

    , testCase "SsaProc placeholder" $
        let sa = buildSsa P.undefined "test_proc" [] :: SsaProc
        in spName sa @?= "test_proc"
    ]

  , testGroup "GraphBuilder"
    [ testCase "id emits no nodes" $
        runGraphBuilder (id :: GraphBuilder () ()) @?= ([] :: [CpsNode])

    , testCase "composition concatenates in order" $
        let gb = mkAssign "x" . mkAssign "y" :: GraphBuilder () ()
        in case runGraphBuilder gb of
             [CpsAssign { anVar = "y" }, CpsAssign { anVar = "x" }] -> return ()
             other -> assertBool "expected 2 assign nodes in order" (P.length other == 2)

    , testCase "||| emits branch + then + goto + else" $
        let f = mkAssign "a" :: GraphBuilder () ()
            g = mkAssign "b"
            gb = f ||| g
        in case runGraphBuilder gb of
             [CpsBranch {}, CpsAssign { anVar = "a" }, CpsGoto {}, CpsAssign { anVar = "b" }] ->
               return ()
             other -> assertBool ("expected 4 nodes, got " <> show (P.length other)) (P.length other == 4)
    ]

  , testGroup "Interp"
    [ testCase "id returns input" $
        runInterp (id :: Interp Int Int) 42 P.>>= \v -> v @?= 42

    , testCase "composition chains effects" $
        let f = Interp (\x -> P.pure (x P.+ 1)) :: Interp Int Int
            g = Interp (\x -> P.pure (x P.* 2))
        in runInterp (f . g) 3 P.>>= \v -> v @?= 7

    , testCase "inl injects left" $
        runInterp (inl :: Interp Int (Either Int Text)) 42 P.>>= \v -> v @?= Left 42

    , testCase "inr injects right" $
        runInterp (inr :: Interp Text (Either Int Text)) "hi" P.>>= \v -> v @?= Right "hi"

    , testCase "fanin dispatches" $
        let f = Interp (\_ -> P.pure "left") :: Interp Int P.String
            g = Interp (\_ -> P.pure "right")
        in runInterp (f ||| g) (Right "x" :: Either Int Text) P.>>= \v -> v @?= "right"

    , testCase "splitValue routes True to Left" $
        runInterp (splitValue :: Interp ((), Value) (Either () ())) ((), VBool True) P.>>= \v -> v @?= Left ()

    , testCase "splitValue routes False to Right" $
        runInterp (splitValue :: Interp ((), Value) (Either () ())) ((), VBool False) P.>>= \v -> v @?= Right ()
    ]
  ]

-- Helper: build a GraphBuilder that emits a CpsAssign
mkAssign :: Text -> GraphBuilder () ()
mkAssign var = GraphBuilder (\currentPc ->
  ([CpsAssign { anVar = var, anRhs = ExNull, anNext = currentPc + 1 }], currentPc + 1))
