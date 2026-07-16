module CallClassifyTest (tests) where

import PB.Prelude
import PB.AST.Expr             (Expr (..), Lvalue (..), LvSegment (..))
import PB.AST.Type              (PbType (..))
import PB.Analysis.CallClassify (CallKind (..), EffectTag (..), classifyExpr,
                                  classifyEffects, resolveReceiverType)
import PB.Analysis.TypeEnv      (ScopedTypeEnv (..))
import ControlHierarchyTest     (withFyloFixture)

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T

import Test.Tasty           (TestTree, testGroup)
import Test.Tasty.HUnit     (testCase, (@?=))

-- | Bare (unsubscripted) lvalue segment.
seg :: Text -> LvSegment
seg n = LvSegment n Nothing

lv :: [Text] -> Lvalue
lv = Lvalue . map seg

emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv
  { steGlobal = Map.empty, steInstance = Map.empty, steLocal = Map.empty
  , steHierarchy = Map.empty, steObject = "", steControlIndex = Map.empty
  }

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
  , testGroup "effect tags (T0-6)" $
    [ testCase (T.unpack ("builtin free fn " <> name <> " -> " <> T.pack (show (Set.toList tags)))) $
        classifyEffects emptyEnv (ExCall (lv [name]) []) @?= tags
    | (name, tags) <- builtinEffectCases
    ]
    ++
    [ testCase (T.unpack ("dw method " <> meth <> " -> " <> T.pack (show (Set.toList tags)))) $
        classifyEffects dwEnv (ExMethodCall (ExLvalue (lv ["dw_1"])) meth []) @?= tags
    | (meth, tags) <- dwMethodCases
    ]
    ++
    [ testCase (T.unpack ("transaction method " <> meth <> " -> " <> T.pack (show (Set.toList tags)))) $
        classifyEffects transEnv (ExMethodCall (ExLvalue (lv ["tr_1"])) meth []) @?= tags
    | (meth, tags) <- transMethodCases
    ]
    ++
    [ testCase "unrecognized free function -> empty set" $
        classifyEffects emptyEnv (ExCall (lv ["some_unrecognized_fn"]) []) @?= Set.empty
    , testCase "untyped receiver method -> empty set" $
        classifyEffects emptyEnv (ExMethodCall (ExLvalue (lv ["untyped_var"])) "retrieve" []) @?= Set.empty
    , testCase "Suspends tag agrees with classifyExpr's SuspendCall verdict (consistency)" $
        withFyloFixture $ \idx inh -> do
          let env = ScopedTypeEnv
                { steGlobal = Map.empty, steInstance = Map.empty, steLocal = Map.empty
                , steHierarchy = inh, steObject = "w_misth_fylo_form", steControlIndex = idx
                }
              expr = ExCall (lv ["tab1", "page1", "uo_epidom", "dw", "retrieve"]) []
          Set.member Suspends (classifyEffects env expr) @?= (classifyExpr env expr == SuspendCall)
    , testCase "unresolvable multi-hop root: no Suspends tag, matches classifyExpr's PureCall (consistency)" $
        withFyloFixture $ \idx inh -> do
          let env = ScopedTypeEnv
                { steGlobal = Map.empty, steInstance = Map.empty, steLocal = Map.empty
                , steHierarchy = inh, steObject = "w_misth_fylo_form", steControlIndex = idx
                }
              expr = ExCall (lv ["nonexistent_ctrl", "sub_ctrl", "retrieve"]) []
          Set.member Suspends (classifyEffects env expr) @?= (classifyExpr env expr == SuspendCall)
    ]
  ]
  where
    dwEnv    = emptyEnv { steInstance = Map.singleton "dw_1" (PtPrimitive "datawindow") }
    transEnv = emptyEnv { steInstance = Map.singleton "tr_1" (PtPrimitive "transaction") }

    builtinEffectCases :: [(Text, Set.Set EffectTag)]
    builtinEffectCases =
      [ ("open",             Set.fromList [Suspends, WritesUi])
      , ("opensheet",        Set.fromList [Suspends, WritesUi])
      , ("close",            Set.fromList [Suspends, WritesUi])
      , ("fn_retrievechild", Set.fromList [Suspends, ReadsDb])
      , ("execute",          Set.singleton Suspends)
      , ("run",              Set.singleton Suspends)
      ]

    dwMethodCases :: [(Text, Set.Set EffectTag)]
    dwMethodCases =
      [ ("retrieve",  Set.fromList [Suspends, ReadsDb])
      , ("update",    Set.fromList [Suspends, WritesDb])
      , ("delete",    Set.fromList [Suspends, WritesDb])
      , ("reset",     Set.fromList [Suspends, WritesDb])
      , ("rowscopy",  Set.fromList [Suspends, WritesDb])
      , ("rowsmove",  Set.fromList [Suspends, WritesDb])
      , ("sharedata", Set.fromList [Suspends, WritesDb])
      , ("modify",    Set.fromList [Suspends, WritesDb])
      , ("print",     Set.fromList [Suspends, WritesUi])
      ]

    transMethodCases :: [(Text, Set.Set EffectTag)]
    transMethodCases =
      [ ("commit",     Set.fromList [Suspends, WritesDb])
      , ("rollback",   Set.singleton Suspends)
      , ("connect",    Set.singleton Suspends)
      , ("disconnect", Set.singleton Suspends)
      , ("autocommit", Set.singleton Suspends)
      ]
