module CallClassifyTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt         (BodyStmt (..))
import PB.AST.Expr             (Expr (..), Lvalue (..), LvSegment (..))
import PB.AST.Ident            (mkIdent)
import PB.AST.Located          (Located (..))
import PB.AST.SourceFile
import PB.AST.Type              (PbType (..))
import PB.Lexing.Token          (SourceSpan (..))
import PB.Analysis.CallClassify (CallKind (..), EffectTag (..), ProcUnit (..), classifyExpr,
                                  classifyEffects, forProcedures, resolveReceiverType)
import PB.Analysis.ControlHierarchy (buildControlIndex)
import PB.Analysis.TypeEnv      (ScopedTypeEnv (..), buildWorkspaceEnv)
import ControlHierarchyTest     (withFyloFixture)

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T

import Test.Tasty           (TestTree, testGroup)
import Test.Tasty.HUnit     (assertFailure, testCase, (@?=))

emptyFile :: SrFile
emptyFile = SrFile [] Nothing Nothing [] [] [] [] [] [] []

-- | Bare (unsubscripted) lvalue segment.
seg :: Text -> LvSegment
seg n = LvSegment (mkIdent n) Nothing

lv :: [Text] -> Lvalue
lv = Lvalue . map seg

emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv
  { steGlobal = Map.empty, steInstance = Map.empty, steLocal = Map.empty
  , steHierarchy = Map.empty, steObject = "", steControlIndex = Map.empty, steParams = Set.empty, steParamIndex = Map.empty
  }

-- | Fixture helpers for 'forProcedures' -- one param, one body-local, so a
-- unit's 'puEnv' can be checked for both the params 'procEnv' seeds and the
-- 'collectBodyLocals' fold on top.
mkParam :: Text -> Param
mkParam nm = Param [] "integer" (SourceSpan 1 1 1 1) (mkIdent nm)

localVarStmt :: Text -> Located BodyStmt
localVarStmt nm = Located 1 (BsLocalVar [] (PtPrimitive "string") (mkIdent nm) Nothing)

fnUnit :: Text -> FunctionBlock
fnUnit nm = FunctionBlock
  { fbSig = FnSig { fnsMods = [], fnsReturnType = "integer", fnsReturnTypeSpan = SourceSpan 1 1 1 1
                  , fnsName = mkIdent nm, fnsParams = [mkParam "ai_p"], fnsThrows = Nothing
                  , fnsLibrary = Nothing, fnsAliasFor = Nothing }
  , fbBody = [localVarStmt "ls_local"]
  }

subUnit :: Text -> SubroutineBlock
subUnit nm = SubroutineBlock
  { sbSig = SubSig { ssMods = [], ssName = mkIdent nm, ssParams = [], ssThrows = Nothing
                    , ssLibrary = Nothing, ssAliasFor = Nothing }
  , sbBody = []
  }

evUnit :: Text -> EventBlock
evUnit nm = EventBlock
  { evSig = EventSig { esName = mkIdent nm, esParams = [] }
  , evOwner = Nothing
  , evBody = []
  }

onUnit :: Text -> Text -> OnBlock
onUnit owner ev = OnBlock
  { obQualName = mkIdent (owner <> "`" <> ev)
  , obOwner = mkIdent owner
  , obEvent = mkIdent ev
  , obBody = []
  }

tests :: TestTree
tests = testGroup "CallClassify"
  [ testGroup "multi-hop receiver resolution (D4)"
    [ testCase "ExCall multi-hop dotted chain (tab1.page1.uo_epidom.dw.Retrieve()) -> SuspendCall" $
        withFyloFixture $ \idx inh -> do
          let env = ScopedTypeEnv
                { steGlobal = Map.empty, steInstance = Map.empty, steLocal = Map.empty
                , steHierarchy = inh, steObject = "w_misth_fylo_form", steControlIndex = idx, steParams = Set.empty, steParamIndex = Map.empty
                }
              expr = ExCall (lv ["tab1", "page1", "uo_epidom", "dw", "retrieve"]) []
          classifyExpr env expr @?= SuspendCall

    , testCase "ExMethodCall multi-hop receiver (tab1.page1.uo_epidom.dw).Retrieve() -> SuspendCall" $
        withFyloFixture $ \idx inh -> do
          let env = ScopedTypeEnv
                { steGlobal = Map.empty, steInstance = Map.empty, steLocal = Map.empty
                , steHierarchy = inh, steObject = "w_misth_fylo_form", steControlIndex = idx, steParams = Set.empty, steParamIndex = Map.empty
                }
              recv = ExLvalue (lv ["tab1", "page1", "uo_epidom", "dw"])
          resolveReceiverType env recv @?= Just "datawindow"
          classifyExpr env (ExMethodCall recv "retrieve" []) @?= SuspendCall

    , testCase "unresolvable multi-hop root -> PureCall (fallback, no guessing)" $
        withFyloFixture $ \idx inh -> do
          let env = ScopedTypeEnv
                { steGlobal = Map.empty, steInstance = Map.empty, steLocal = Map.empty
                , steHierarchy = inh, steObject = "w_misth_fylo_form", steControlIndex = idx, steParams = Set.empty, steParamIndex = Map.empty
                }
              expr = ExCall (lv ["nonexistent_ctrl", "sub_ctrl", "retrieve"]) []
          classifyExpr env expr @?= PureCall

    , testCase "single-segment receiver unaffected: dw_1.Retrieve() -> SuspendCall via instance var" $
        let env = ScopedTypeEnv
              { steGlobal = Map.empty
              , steInstance = Map.singleton "dw_1" (PtPrimitive "datawindow")
              , steLocal = Map.empty
              , steHierarchy = Map.empty, steObject = "", steControlIndex = Map.empty, steParams = Set.empty, steParamIndex = Map.empty
              }
            recv = ExLvalue (lv ["dw_1"])
        in classifyExpr env (ExMethodCall recv "retrieve" []) @?= SuspendCall

    , testCase "single-segment receiver never in steLocal/steInstance/steGlobal falls back to a 1-hop ControlIndex lookup (Plan 195 Phase D)" $
        -- A visual control (e.g. dw_1) is declared as its own nested
        -- TypeBlock, never as a BsLocalVar -- steInstance alone can never
        -- see it. resolveLvalueType's single-segment branch must fall back
        -- to the same ControlIndex the 2+-segment chain branch already uses.
        let idx = buildControlIndex
              [ emptyFile { srTypeBlocks =
                  [ TypeBlock (mkTypeDecl "w_main" "window" Nothing) []
                  , TypeBlock (mkTypeDecl "dw_1" "datawindow" (Just "w_main")) []
                  ] } ]
            env = ScopedTypeEnv
              { steGlobal = Map.empty, steInstance = Map.empty, steLocal = Map.empty
              , steHierarchy = Map.empty, steObject = "w_main", steControlIndex = idx, steParams = Set.empty, steParamIndex = Map.empty
              }
            recv = ExLvalue (lv ["dw_1"])
        in do
          resolveReceiverType env recv @?= Just "datawindow"
          classifyExpr env (ExMethodCall recv "retrieve" []) @?= SuspendCall

    , testCase "'this' receiver resolves to the enclosing object's own type" $
        let env = ScopedTypeEnv
              { steGlobal = Map.empty, steInstance = Map.empty, steLocal = Map.empty
              , steHierarchy = Map.empty, steObject = "w_main", steControlIndex = Map.empty, steParams = Set.empty, steParamIndex = Map.empty
              }
        in resolveReceiverType env (ExLvalue (lv ["this"])) @?= Just "w_main"

    , testCase "'super' receiver resolves to the enclosing object's immediate ancestor" $
        let env = ScopedTypeEnv
              { steGlobal = Map.empty, steInstance = Map.empty, steLocal = Map.empty
              , steHierarchy = Map.singleton "w_child" "w_parent"
              , steObject = "w_child", steControlIndex = Map.empty, steParams = Set.empty, steParamIndex = Map.empty
              }
        in resolveReceiverType env (ExLvalue (lv ["super"])) @?= Just "w_parent"
    ]
  , testGroup "effect tags (T0-6)" $
    [ testCase (T.unpack ("builtin free fn " <> name <> " -> " <> T.pack (show (Set.toList tags)))) $
        classifyEffects emptyEnv (ExCall (lv [name]) []) @?= tags
    | (name, tags) <- builtinEffectCases
    ]
    ++
    [ testCase (T.unpack ("dw method " <> meth <> " -> " <> T.pack (show (Set.toList tags)))) $
        classifyEffects dwEnv (ExMethodCall (ExLvalue (lv ["dw_1"])) (mkIdent meth) []) @?= tags
    | (meth, tags) <- dwMethodCases
    ]
    ++
    [ testCase (T.unpack ("transaction method " <> meth <> " -> " <> T.pack (show (Set.toList tags)))) $
        classifyEffects transEnv (ExMethodCall (ExLvalue (lv ["tr_1"])) (mkIdent meth) []) @?= tags
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
                , steHierarchy = inh, steObject = "w_misth_fylo_form", steControlIndex = idx, steParams = Set.empty, steParamIndex = Map.empty
                }
              expr = ExCall (lv ["tab1", "page1", "uo_epidom", "dw", "retrieve"]) []
          Set.member Suspends (classifyEffects env expr) @?= (classifyExpr env expr == SuspendCall)
    , testCase "unresolvable multi-hop root: no Suspends tag, matches classifyExpr's PureCall (consistency)" $
        withFyloFixture $ \idx inh -> do
          let env = ScopedTypeEnv
                { steGlobal = Map.empty, steInstance = Map.empty, steLocal = Map.empty
                , steHierarchy = inh, steObject = "w_misth_fylo_form", steControlIndex = idx, steParams = Set.empty, steParamIndex = Map.empty
                }
              expr = ExCall (lv ["nonexistent_ctrl", "sub_ctrl", "retrieve"]) []
          Set.member Suspends (classifyEffects env expr) @?= (classifyExpr env expr == SuspendCall)
    ]
  , testGroup "forProcedures (Plan 197 Finding 7)"
    [ testCase "empty SrFile yields no units" $
        forProcedures emptyWsEnv emptyIdx "w_test" emptyFile @?= []

    , testCase "preserves functions++subroutines++events++on-blocks order" $
        let sf = emptyFile
              { srFunctions   = [fnUnit "of_a"]
              , srSubroutines = [subUnit "us_b"]
              , srEvents      = [evUnit "ue_c"]
              , srOnBlocks    = [onUnit "w_test" "open"]
              }
        in map puName (forProcedures emptyWsEnv emptyIdx "w_test" sf)
             @?= ["of_a", "us_b", "ue_c", "open"]

    , testCase "each unit carries its own kind" $
        let sf = emptyFile
              { srFunctions   = [fnUnit "of_a"]
              , srSubroutines = [subUnit "us_b"]
              , srEvents      = [evUnit "ue_c"]
              , srOnBlocks    = [onUnit "w_test" "open"]
              }
        in map puKind (forProcedures emptyWsEnv emptyIdx "w_test" sf)
             @?= ["function", "subroutine", "event", "on"]

    , testCase "on-block unit has empty params" $
        let sf = emptyFile { srOnBlocks = [onUnit "w_test" "open"] }
        in map puParams (forProcedures emptyWsEnv emptyIdx "w_test" sf) @?= [[]]

    , testCase "function unit's puEnv folds body locals over procEnv's param seeding" $
        let sf = emptyFile { srFunctions = [fnUnit "of_a"] }
        in case forProcedures emptyWsEnv emptyIdx "w_test" sf of
             [pu] -> do
               Map.lookup "ai_p" (steLocal (puEnv pu)) @?= Just (PtPrimitive "integer")
               Map.lookup "ls_local" (steLocal (puEnv pu)) @?= Just (PtPrimitive "string")
               steParams (puEnv pu) @?= Set.singleton "ai_p"
             other -> assertFailure ("expected exactly one unit, got " <> show (length other))

    , testCase "function unit carries its declared return type/span" $
        let sf = emptyFile { srFunctions = [fnUnit "of_a"] }
        in case forProcedures emptyWsEnv emptyIdx "w_test" sf of
             [pu] -> do
               puRetType pu @?= "integer"
               puRetTypeSpan pu @?= Just (SourceSpan 1 1 1 1)
             other -> assertFailure ("expected exactly one unit, got " <> show (length other))
    ]
  ]
  where
    emptyWsEnv = buildWorkspaceEnv []
    emptyIdx   = buildControlIndex []

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
