module TypeEnvTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt       (BodyStmt (..))
import PB.AST.Located        (Located (..))
import PB.AST.Ident          (identOrig, identCanon, identSetMember, mkIdent)
import PB.AST.SourceFile     (SrFile (..), ForwardBlock (..), TypeBlock (..),
                              GlobalInstance (..), srAllTypeDecls, srPrimaryObject,
                              splitAncestorRef, mkTypeDecl)
import PB.AST.Type           (PbType (..), parseTypeText)
import PB.Analysis.TypeEnv   (TypeEnv (..), buildWorkspaceTypeEnv, lookupVarType, lookupUserType,
                              lookupBaseType, isDescendantOf,
                              ScopedTypeEnv (..), buildWorkspaceEnv,
                              procEnv, lookupScopedVar, lookupScopedVarOrSelf,
                              lookupInstanceVarOwner)
import PB.Analysis.TypeResolve (buildObjectSet, buildUserTypeSet)

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import Test.Tasty            (TestTree, testGroup)
import Test.Tasty.HUnit      (testCase, (@?=))

emptyFile :: SrFile
emptyFile = SrFile [] Nothing Nothing [] [] [] [] [] [] []

tests :: TestTree
tests = testGroup "TypeEnv"
  [ testGroup "buildWorkspaceTypeEnv"
    [ testCase "empty file produces empty env" $
        let env = buildWorkspaceTypeEnv [emptyFile]
        in lookupVarType "x" env @?= Nothing

    ]

  , testGroup "lookupUserType"
    [ testCase "type decl from forward block is found" $
        let sf = emptyFile
                  { srForward = Just (ForwardBlock
                      { fwdTypes = [mkTypeDecl "w_foo" "window" Nothing]
                      , fwdInstances = []
                      })}
            env = buildWorkspaceTypeEnv [sf]
        in lookupUserType "w_foo" env @?= Just "window"

    , testCase "type decl from type block is found" $
        let tb = TypeBlock (mkTypeDecl "nvo_utils" "nonvisualobject" Nothing) []
            sf = emptyFile { srTypeBlocks = [tb] }
            env = buildWorkspaceTypeEnv [sf]
        in lookupUserType "nvo_utils" env @?= Just "nonvisualobject"

    , testCase "unknown type returns Nothing" $
        let env = buildWorkspaceTypeEnv [emptyFile]
        in lookupUserType "w_unknown" env @?= Nothing
    ]

  , testGroup "lookupBaseType"
    [ testCase "primitive type returns lowercased name" $
        let env = TypeEnv
              { teVars      = Map.fromList [("x", PtPrimitive "Integer")]
              , teUserTypes = Map.empty
              }
        in lookupBaseType "x" env @?= Just "integer"

    , testCase "user type walks single inheritance step" $
        let env = TypeEnv
              { teVars      = Map.fromList [("dw", PtUserDefined "datawindow")]
              , teUserTypes = Map.fromList [("datawindow", "nonvisualobject")]
              }
        in lookupBaseType "dw" env @?= Just "nonvisualobject"

    , testCase "user type walks multi-step chain" $
        let env = TypeEnv
              { teVars      = Map.fromList [("svc", PtUserDefined "n_cst_service")]
              , teUserTypes = Map.fromList
                  [ ("n_cst_service", "nonvisualobject")
                  , ("nonvisualobject", "object")
                  ]
              }
        in lookupBaseType "svc" env @?= Just "object"

    , testCase "cycle guard terminates" $
        -- a → b → a (cycle): walk returns when it revisits "a", so result is "a"
        let env = TypeEnv
              { teVars      = Map.fromList [("x", PtUserDefined "a")]
              , teUserTypes = Map.fromList [("a", "b"), ("b", "a")]
              }
        in lookupBaseType "x" env @?= Just "a"

    , testCase "unknown var returns Nothing" $
        let env = TypeEnv { teVars = Map.empty, teUserTypes = Map.empty }
        in lookupBaseType "x" env @?= Nothing

    , testCase "lookup is case-insensitive on var name" $
        let env = TypeEnv
              { teVars      = Map.fromList [("dw_main", PtUserDefined "datawindow")]
              , teUserTypes = Map.empty
              }
        in lookupBaseType "DW_Main" env @?= Just "datawindow"

    , testCase "walk matches an ancestor-map entry keyed in a different case than the rendered var type, preserving the stored entry's own casing (Ident-keyed teUserTypes, Plan 179 Phase 1)" $
        let env = TypeEnv
              { teVars      = Map.fromList [(mkIdent "dw", PtUserDefined "DataWindow")]
              , teUserTypes = Map.fromList [(mkIdent "DataWindow", mkIdent "NonVisualObject")]
              }
        in fmap identOrig (lookupBaseType (mkIdent "dw") env) @?= Just "NonVisualObject"
    ]

  , testGroup "parseTypeText"
    [ testCase "primitive types are recognized" $
        parseTypeText "integer" @?= PtPrimitive "integer"

    , testCase "any is recognized" $
        parseTypeText "any" @?= PtAny

    , testCase "user-defined types are recognized" $
        parseTypeText "w_main" @?= PtUserDefined "w_main"

    , testCase "decimal with precision is parsed" $
        parseTypeText "decimal{10}" @?= PtDecimalPrec 10

    , testCase "case insensitive" $
        parseTypeText "INTEGER" @?= PtPrimitive "integer"
    ]

  , testGroup "srPrimaryObject"
    [ testCase "forward fallback when type blocks empty" $
        let sf = emptyFile
                  { srForward = Just (ForwardBlock
                      { fwdTypes = [mkTypeDecl "u_st" "pfc_u_st" Nothing]
                      , fwdInstances = [] })}
        in srPrimaryObject sf @?= ("u_st", Just "pfc_u_st")

    , testCase "type block wins over forward block" $
        let sf = emptyFile
                  { srForward = Just (ForwardBlock
                      { fwdTypes = [mkTypeDecl "u_st" "pfc_u_st" Nothing]
                      , fwdInstances = [] })
                  , srTypeBlocks = [TypeBlock (mkTypeDecl "u_st" "window" Nothing) []] }
        in srPrimaryObject sf @?= ("u_st", Just "window")

    , testCase "empty file returns empty" $
        srPrimaryObject emptyFile @?= ("", Nothing)

    , testCase "forward block with no types returns empty" $
        let sf = emptyFile
                  { srForward = Just (ForwardBlock
                      { fwdTypes = []
                      , fwdInstances = [GlobalInstance "menu" "m_item"] }) }
        in srPrimaryObject sf @?= ("", Nothing)

    , testCase "prefers type block matching forward's first entry over textually-first type block" $
        -- Real corpus shape (pbexamw1.pbl/w_dw_copy.srw): a top-level
        -- `type os_data from structure` block is declared before the file's
        -- real `global type w_dw_copy from w_center` block, but the forward
        -- block's first entry names w_dw_copy as the file's own type.
        let sf = emptyFile
                  { srForward = Just (ForwardBlock
                      { fwdTypes = [mkTypeDecl "w_dw_copy" "w_center" Nothing]
                      , fwdInstances = [] })
                  , srTypeBlocks =
                      [ TypeBlock (mkTypeDecl "os_data" "structure" Nothing) []
                      , TypeBlock (mkTypeDecl "w_dw_copy" "w_center" Nothing) []
                      ] }
        in srPrimaryObject sf @?= ("w_dw_copy", Just "w_center")

    , testCase "falls back to first type block when forward's first entry matches nothing" $
        let sf = emptyFile
                  { srForward = Just (ForwardBlock
                      { fwdTypes = [mkTypeDecl "nonexistent" "window" Nothing]
                      , fwdInstances = [] })
                  , srTypeBlocks = [TypeBlock (mkTypeDecl "os_data" "structure" Nothing) []] }
        in srPrimaryObject sf @?= ("os_data", Just "structure")
    ]

  , testGroup "srAllTypeDecls"
    [ testCase "merges type blocks and forward block" $
        let sf = emptyFile
                  { srTypeBlocks = [TypeBlock (mkTypeDecl "w_main" "window" Nothing) []]
                  , srForward = Just (ForwardBlock
                      { fwdTypes = [mkTypeDecl "u_st" "pfc_u_st" Nothing]
                      , fwdInstances = [] }) }
            decls = srAllTypeDecls sf
        in length decls @?= 2

    , testCase "forward block only" $
        let sf = emptyFile
                  { srForward = Just (ForwardBlock
                      { fwdTypes = [mkTypeDecl "u_st" "pfc_u_st" Nothing]
                      , fwdInstances = [] }) }
        in length (srAllTypeDecls sf) @?= 1

    , testCase "type blocks only" $
        let sf = emptyFile
                  { srTypeBlocks = [TypeBlock (mkTypeDecl "w_main" "window" Nothing) []] }
        in length (srAllTypeDecls sf) @?= 1
    ]

  , testGroup "buildObjectSet"
    [ testCase "forward-only non-structure type is included" $
        let sf = emptyFile
                  { srForward = Just (ForwardBlock
                      { fwdTypes = [mkTypeDecl "u_st" "pfc_u_st" Nothing]
                      , fwdInstances = [] }) }
        in identSetMember "u_st" (buildObjectSet [sf]) @?= True

    , testCase "forward-only structure type is excluded" $
        let sf = emptyFile
                  { srForward = Just (ForwardBlock
                      { fwdTypes = [mkTypeDecl "s_data" "structure" Nothing]
                      , fwdInstances = [] }) }
        in identSetMember "s_data" (buildObjectSet [sf]) @?= False
    ]

  , testGroup "buildUserTypeSet"
    [ testCase "forward-only structure type is included" $
        let sf = emptyFile
                  { srForward = Just (ForwardBlock
                      { fwdTypes = [mkTypeDecl "s_data" "structure" Nothing]
                      , fwdInstances = [] }) }
        in identSetMember "s_data" (buildUserTypeSet [sf]) @?= True

    , testCase "forward-only non-structure type is excluded" $
        let sf = emptyFile
                  { srForward = Just (ForwardBlock
                      { fwdTypes = [mkTypeDecl "u_st" "pfc_u_st" Nothing]
                      , fwdInstances = [] }) }
        in identSetMember "u_st" (buildUserTypeSet [sf]) @?= False
    ]

  , testGroup "extractGlobalVars forward instances"
    [ testCase "forward global instances are included" $
        let sf = emptyFile
                  { srForward = Just (ForwardBlock
                      { fwdTypes = []
                      , fwdInstances = [GlobalInstance "integer" "m_main"] }) }
            env = buildWorkspaceTypeEnv [sf]
        in lookupVarType "m_main" env @?= Just (PtPrimitive "integer")
    ]

  , testGroup "ScopedTypeEnv"
    [ testCase "lookupScopedVar finds local, shadowing instance" $
        let env = ScopedTypeEnv
              { steLocal    = Map.singleton "x" (PtPrimitive "string")
              , steInstance = Map.singleton "x" (PtPrimitive "integer")
              , steGlobal   = Map.empty
              , steHierarchy = Map.empty
              , steObject = "", steControlIndex = Map.empty, steParams = Set.empty, steParamIndex = Map.empty
              }
        in lookupScopedVar "x" env @?= Just (PtPrimitive "string")

    , testCase "lookupScopedVar finds instance, shadowing global" $
        let env = ScopedTypeEnv
              { steLocal    = Map.empty
              , steInstance = Map.singleton "y" (PtPrimitive "long")
              , steGlobal   = Map.singleton "y" (PtPrimitive "integer")
              , steHierarchy = Map.empty
              , steObject = "", steControlIndex = Map.empty, steParams = Set.empty, steParamIndex = Map.empty
              }
        in lookupScopedVar "y" env @?= Just (PtPrimitive "long")

    , testCase "lookupScopedVar falls through to global" $
        let env = ScopedTypeEnv
              { steLocal    = Map.empty
              , steInstance = Map.empty
              , steGlobal   = Map.singleton "z" (PtPrimitive "boolean")
              , steHierarchy = Map.empty
              , steObject = "", steControlIndex = Map.empty, steParams = Set.empty, steParamIndex = Map.empty
              }
        in lookupScopedVar "z" env @?= Just (PtPrimitive "boolean")

    , testCase "lookupScopedVar is case-insensitive" $
        let env = ScopedTypeEnv
              { steLocal    = Map.singleton "foo" (PtPrimitive "string")
              , steInstance = Map.empty
              , steGlobal   = Map.empty
              , steHierarchy = Map.empty
              , steObject = "", steControlIndex = Map.empty, steParams = Set.empty, steParamIndex = Map.empty
              }
        in lookupScopedVar "FOO" env @?= Just (PtPrimitive "string")

    , testCase "procEnv wires correct instance layer for obj_a" $
        let sfA = emptyFile
              { srTypeBlocks = [TypeBlock (mkTypeDecl "obj_a" "window" Nothing)
                  [Located 1 (BsLocalVar [] (PtPrimitive "integer") "foo" Nothing)]] }
            sfB = emptyFile
              { srTypeBlocks = [TypeBlock (mkTypeDecl "obj_b" "window" Nothing)
                  [Located 1 (BsLocalVar [] (PtPrimitive "string") "foo" Nothing)]] }
            ws  = buildWorkspaceEnv [sfA, sfB]
        in lookupScopedVar "foo" (procEnv ws Map.empty "obj_a" []) @?= Just (PtPrimitive "integer")

    , testCase "procEnv wires correct instance layer for obj_b" $
        let sfA = emptyFile
              { srTypeBlocks = [TypeBlock (mkTypeDecl "obj_a" "window" Nothing)
                  [Located 1 (BsLocalVar [] (PtPrimitive "integer") "foo" Nothing)]] }
            sfB = emptyFile
              { srTypeBlocks = [TypeBlock (mkTypeDecl "obj_b" "window" Nothing)
                  [Located 1 (BsLocalVar [] (PtPrimitive "string") "foo" Nothing)]] }
            ws  = buildWorkspaceEnv [sfA, sfB]
        in lookupScopedVar "foo" (procEnv ws Map.empty "obj_b" []) @?= Just (PtPrimitive "string")

    , testCase "instance var lookup is case-insensitive when TypeBlock declares mixed-case BsLocalVar" $
        let sf = emptyFile
              { srTypeBlocks = [TypeBlock (mkTypeDecl "obj_a" "window" Nothing)
                  [Located 1 (BsLocalVar [] (PtPrimitive "integer") "Li_Count" Nothing)]] }
            ws = buildWorkspaceEnv [sf]
        in lookupScopedVar "li_count" (procEnv ws Map.empty "obj_a" []) @?= Just (PtPrimitive "integer")

    , testCase "procEnv resolves an instance var declared only on the ancestor object" $
        let sfParent = emptyFile
              { srTypeBlocks = [TypeBlock (mkTypeDecl "w_parent" "window" Nothing)
                  [Located 1 (BsLocalVar [] (PtPrimitive "integer") "ai_count" Nothing)]] }
            sfChild = emptyFile
              { srTypeBlocks = [TypeBlock (mkTypeDecl "w_child" "w_parent" Nothing) []] }
            ws = buildWorkspaceEnv [sfParent, sfChild]
        in lookupScopedVar "ai_count" (procEnv ws Map.empty "w_child" []) @?= Just (PtPrimitive "integer")

    , testCase "procEnv's own instance var shadows a same-named ancestor var" $
        let sfParent = emptyFile
              { srTypeBlocks = [TypeBlock (mkTypeDecl "w_parent" "window" Nothing)
                  [Located 1 (BsLocalVar [] (PtPrimitive "integer") "ai_count" Nothing)]] }
            sfChild = emptyFile
              { srTypeBlocks = [TypeBlock (mkTypeDecl "w_child" "w_parent" Nothing)
                  [Located 1 (BsLocalVar [] (PtPrimitive "string") "ai_count" Nothing)]] }
            ws = buildWorkspaceEnv [sfParent, sfChild]
        in lookupScopedVar "ai_count" (procEnv ws Map.empty "w_child" []) @?= Just (PtPrimitive "string")
    ]

  , testGroup "lookupInstanceVarOwner"
    [ testCase "finds the object's own declared instance var" $
        let sf = emptyFile
              { srTypeBlocks = [TypeBlock (mkTypeDecl "w_main" "window" Nothing)
                  [Located 1 (BsLocalVar [] (PtPrimitive "integer") "ai_count" Nothing)]] }
            ws = buildWorkspaceEnv [sf]
        in fmap (\(o, t) -> (identOrig o, t)) (lookupInstanceVarOwner ws "w_main" "ai_count")
             @?= Just ("w_main", PtPrimitive "integer")

    , testCase "walks the ancestor chain to find a var declared only there" $
        let sfParent = emptyFile
              { srTypeBlocks = [TypeBlock (mkTypeDecl "w_parent" "window" Nothing)
                  [Located 1 (BsLocalVar [] (PtPrimitive "integer") "ai_count" Nothing)]] }
            sfChild = emptyFile
              { srTypeBlocks = [TypeBlock (mkTypeDecl "w_child" "w_parent" Nothing) []] }
            ws = buildWorkspaceEnv [sfParent, sfChild]
        in fmap (\(o, t) -> (identOrig o, t)) (lookupInstanceVarOwner ws "w_child" "ai_count")
             @?= Just ("w_parent", PtPrimitive "integer")

    , testCase "own declaration wins over an ancestor's same-named var (nearest first)" $
        let sfParent = emptyFile
              { srTypeBlocks = [TypeBlock (mkTypeDecl "w_parent" "window" Nothing)
                  [Located 1 (BsLocalVar [] (PtPrimitive "integer") "ai_count" Nothing)]] }
            sfChild = emptyFile
              { srTypeBlocks = [TypeBlock (mkTypeDecl "w_child" "w_parent" Nothing)
                  [Located 1 (BsLocalVar [] (PtPrimitive "string") "ai_count" Nothing)]] }
            ws = buildWorkspaceEnv [sfParent, sfChild]
        in fmap (\(o, t) -> (identOrig o, t)) (lookupInstanceVarOwner ws "w_child" "ai_count")
             @?= Just ("w_child", PtPrimitive "string")

    , testCase "returns Nothing when no object in the chain declares the var" $
        let sf = emptyFile
              { srTypeBlocks = [TypeBlock (mkTypeDecl "w_main" "window" Nothing) []] }
            ws = buildWorkspaceEnv [sf]
        in lookupInstanceVarOwner ws "w_main" "nonexistent" @?= Nothing
    ]

  , testGroup "lookupScopedVarOrSelf (this/super)"
    [ testCase "'this' resolves to the enclosing object's own type, regardless of steLocal/steInstance/steGlobal" $
        let env = ScopedTypeEnv
              { steLocal = Map.empty, steInstance = Map.empty, steGlobal = Map.empty
              , steHierarchy = Map.empty, steObject = "w_main", steControlIndex = Map.empty, steParams = Set.empty, steParamIndex = Map.empty
              }
        in lookupScopedVarOrSelf "this" env @?= Just (PtUserDefined "w_main")

    , testCase "'super' resolves one hop up steHierarchy from the enclosing object" $
        let env = ScopedTypeEnv
              { steLocal = Map.empty, steInstance = Map.empty, steGlobal = Map.empty
              , steHierarchy = Map.singleton "w_child" "w_parent"
              , steObject = "w_child", steControlIndex = Map.empty, steParams = Set.empty, steParamIndex = Map.empty
              }
        in lookupScopedVarOrSelf "super" env @?= Just (PtUserDefined "w_parent")

    , testCase "'super' with no ancestor in steHierarchy -> Nothing (never guess)" $
        let env = ScopedTypeEnv
              { steLocal = Map.empty, steInstance = Map.empty, steGlobal = Map.empty
              , steHierarchy = Map.empty, steObject = "w_main", steControlIndex = Map.empty, steParams = Set.empty, steParamIndex = Map.empty
              }
        in lookupScopedVarOrSelf "super" env @?= Nothing

    , testCase "'this'/'super' are case-insensitive keywords" $
        let env = ScopedTypeEnv
              { steLocal = Map.empty, steInstance = Map.empty, steGlobal = Map.empty
              , steHierarchy = Map.singleton "w_child" "w_parent"
              , steObject = "w_child", steControlIndex = Map.empty, steParams = Set.empty, steParamIndex = Map.empty
              }
        in do
          lookupScopedVarOrSelf "This"  env @?= Just (PtUserDefined "w_child")
          lookupScopedVarOrSelf "SUPER" env @?= Just (PtUserDefined "w_parent")

    , testCase "any other name falls back to ordinary lookupScopedVar" $
        let env = ScopedTypeEnv
              { steLocal = Map.singleton "ls_x" (PtPrimitive "string")
              , steInstance = Map.empty, steGlobal = Map.empty
              , steHierarchy = Map.empty, steObject = "w_main", steControlIndex = Map.empty, steParams = Set.empty, steParamIndex = Map.empty
              }
        in lookupScopedVarOrSelf "ls_x" env @?= Just (PtPrimitive "string")
    ]

  , testGroup "isDescendantOf"
    [ testCase "direct match — type is in targets" $
        isDescendantOf Map.empty "datawindow" (Set.singleton "datawindow") @?= True

    , testCase "no parents, not in targets" $
        isDescendantOf Map.empty "integer" (Set.singleton "datawindow") @?= False

    , testCase "one-hop ancestry" $
        let inh = Map.singleton "my_dw" "datawindow"
        in isDescendantOf inh "my_dw" (Set.singleton "datawindow") @?= True

    , testCase "two-hop ancestry (stdlib scenario)" $
        let inh = Map.fromList
              [ ("my_dw", "datawindow")
              , ("datawindow", "nonvisualobject")
              , ("nonvisualobject", "powerobject")
              ]
        in isDescendantOf inh "my_dw" (Set.singleton "datawindow") @?= True

    , testCase "root does not match when not in targets" $
        let inh = Map.fromList
              [ ("datawindow", "nonvisualobject")
              , ("nonvisualobject", "powerobject")
              ]
        in isDescendantOf inh "powerobject" (Set.singleton "datawindow") @?= False

    , testCase "cycle guard — does not loop forever" $
        let inh = Map.fromList [("a", "b"), ("b", "a")]
        in isDescendantOf inh "a" (Set.singleton "c") @?= False
    ]

  , testGroup "splitAncestorRef"
    [ testCase "no backtick returns whole text unchanged, Nothing" $
        splitAncestorRef "w_form_tab2" @?= ("w_form_tab2", Nothing)

    , testCase "backtick splits into ancestor class and override name" $
        splitAncestorRef "w_form_tab2`page1" @?= ("w_form_tab2", Just "page1")

    , testCase "real corpus shape (w_misth_fylo_form.srw's page1)" $
        splitAncestorRef "w_form_tab2`page1" @?= ("w_form_tab2", Just "page1")

    , testCase "empty text" $
        splitAncestorRef "" @?= ("", Nothing)

    , testCase "backtick at start yields empty ancestor class" $
        splitAncestorRef "`dw_1" @?= ("", Just "dw_1")

    , testCase "multiple backticks split at the first only" $
        splitAncestorRef "a`b`c" @?= ("a", Just "b`c")

    , testCase "identOrig preserves original casing on both split halves" $
        let (anc, ovr) = splitAncestorRef "W_Form_Tab2`Page1"
        in (identOrig anc, identOrig <$> ovr) @?= ("W_Form_Tab2", Just "Page1")

    , testCase "identCanon lowercases both split halves" $
        let (anc, ovr) = splitAncestorRef "W_Form_Tab2`Page1"
        in (identCanon anc, identCanon <$> ovr) @?= ("w_form_tab2", Just "page1")
    ]

  , testGroup "extractTypeDecls backtick handling (via lookupUserType/lookupBaseType)"
    [ testCase "backtick ancestor resolves to the class part, not the raw compound string" $
        let tb  = TypeBlock (mkTypeDecl "page1" "w_form_tab2`page1" (Just "tab1")) []
            sf  = emptyFile { srTypeBlocks = [tb] }
            env = buildWorkspaceTypeEnv [sf]
        in lookupUserType "page1" env @?= Just "w_form_tab2"

    , testCase "chain walk continues through a backtick-declared intermediate type" $
        let tbPage = TypeBlock (mkTypeDecl "page1" "w_form_tab2`page1" (Just "tab1")) []
            tbBase = TypeBlock (mkTypeDecl "w_form_tab2" "window" Nothing) []
            sf  = emptyFile { srTypeBlocks = [tbPage, tbBase] }
            env = TypeEnv
              { teVars      = Map.fromList [("uo_x", PtUserDefined "page1")]
              , teUserTypes = teUserTypes (buildWorkspaceTypeEnv [sf])
              }
        in lookupBaseType "uo_x" env @?= Just "window"
    ]
  ]
