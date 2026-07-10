module CallClassifyTest (tests) where

import PB.Prelude
import PB.AST.Expr             (Expr (..), Lvalue (..), LvSegment (..))
import PB.AST.Type              (PbType (..))
import PB.Analysis.CallClassify (CallKind (..), classifyExpr, resolveReceiverType)
import PB.Analysis.TypeEnv      (ScopedTypeEnv (..))
import ControlHierarchyTest     (withFyloFixture)

import qualified Data.Map.Strict as Map

import Test.Tasty           (TestTree, testGroup)
import Test.Tasty.HUnit     (testCase, (@?=))

-- | Bare (unsubscripted) lvalue segment.
seg :: Text -> LvSegment
seg n = LvSegment n Nothing

lv :: [Text] -> Lvalue
lv = Lvalue . map seg

tests :: TestTree
tests = testGroup "CallClassify"
  [ testGroup "multi-hop receiver resolution (D4)"
    [ testCase "ExCall multi-hop dotted chain (tab1.page1.uo_epidom.dw.Retrieve()) -> SuspendCall" $
        withFyloFixture $ \idx inh -> do
          let env = ScopedTypeEnv
                { steGlobal = Map.empty, steInstance = Map.empty, steLocal = Map.empty
                , steHierarchy = inh, steObject = "w_misth_fylo_form", steControlIndex = idx
                }
              expr = ExCall (lv ["tab1", "page1", "uo_epidom", "dw", "retrieve"]) []
          classifyExpr env expr @?= SuspendCall

    , testCase "ExMethodCall multi-hop receiver (tab1.page1.uo_epidom.dw).Retrieve() -> SuspendCall" $
        withFyloFixture $ \idx inh -> do
          let env = ScopedTypeEnv
                { steGlobal = Map.empty, steInstance = Map.empty, steLocal = Map.empty
                , steHierarchy = inh, steObject = "w_misth_fylo_form", steControlIndex = idx
                }
              recv = ExLvalue (lv ["tab1", "page1", "uo_epidom", "dw"])
          resolveReceiverType env recv @?= Just "datawindow"
          classifyExpr env (ExMethodCall recv "retrieve" []) @?= SuspendCall

    , testCase "unresolvable multi-hop root -> PureCall (fallback, no guessing)" $
        withFyloFixture $ \idx inh -> do
          let env = ScopedTypeEnv
                { steGlobal = Map.empty, steInstance = Map.empty, steLocal = Map.empty
                , steHierarchy = inh, steObject = "w_misth_fylo_form", steControlIndex = idx
                }
              expr = ExCall (lv ["nonexistent_ctrl", "sub_ctrl", "retrieve"]) []
          classifyExpr env expr @?= PureCall

    , testCase "single-segment receiver unaffected: dw_1.Retrieve() -> SuspendCall via instance var" $
        let env = ScopedTypeEnv
              { steGlobal = Map.empty
              , steInstance = Map.singleton "dw_1" (PtPrimitive "datawindow")
              , steLocal = Map.empty
              , steHierarchy = Map.empty, steObject = "", steControlIndex = Map.empty
              }
            recv = ExLvalue (lv ["dw_1"])
        in classifyExpr env (ExMethodCall recv "retrieve" []) @?= SuspendCall
    ]
  ]
