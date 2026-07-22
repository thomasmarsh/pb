module TypeEnvTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt       (BodyStmt (..))
import PB.AST.Located        (Located (..))
import PB.AST.Ident          (IdentProvenance (..), identCanon, identOrig, identSetMember, identSpan, mkIdent, mkIdentAt)
import PB.Lexing.Token       (SourceSpan (..))
import PB.AST.SourceFile     (SrFile (..), ForwardBlock (..), TypeBlock (..),
                              GlobalInstance (..), srAllTypeDecls, srPrimaryObject,
                              splitAncestorRef, mkTypeDecl)
import PB.AST.Type           (PbType (..), parseTypeText, parseTypeTextAt)
import PB.Analysis.TypeEnv   (isDescendantOf, ancestorChain,
                              WorkspaceEnv (..), ScopedTypeEnv (..), buildWorkspaceEnv,
                              procEnv, lookupScopedVar, lookupScopedVarOrSelf,
                              lookupInstanceVarOwner)
import PB.Analysis.TypeResolve (buildObjectSet, buildUserTypeSet)

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import Data.List.NonEmpty     (NonEmpty (..))
import Test.Tasty            (TestTree, testGroup)
import Test.Tasty.HUnit      (assertFailure, testCase, (@?=))

emptyFile :: SrFile
emptyFile = SrFile [] Nothing Nothing [] [] [] [] [] [] []

tests :: TestTree
tests = testGroup "TypeEnv"
  [ testGroup "weHierarchy"
    [ testCase "type decl from forward block is found" $
        let sf = emptyFile
                  { srForward = Just (ForwardBlock
                      { fwdTypes = [mkTypeDecl "w_foo" "window" Nothing]
                      , fwdInstances = []
                      })}
            inh = weHierarchy (buildWorkspaceEnv [sf])
        in Map.lookup "w_foo" inh @?= Just "window"

    , testCase "type decl from type block is found" $
        let tb = TypeBlock (mkTypeDecl "nvo_utils" "nonvisualobject" Nothing) []
            sf = emptyFile { srTypeBlocks = [tb] }
            inh = weHierarchy (buildWorkspaceEnv [sf])
        in Map.lookup "nvo_utils" inh @?= Just "nonvisualobject"

    , testCase "unknown type returns Nothing" $
        let inh = weHierarchy (buildWorkspaceEnv [emptyFile])
        in Map.lookup "w_unknown" inh @?= Nothing

    , testCase "lookup is case-insensitive on type name" $
        let tb  = TypeBlock (mkTypeDecl "dw_main" "datawindow" Nothing) []
            sf  = emptyFile { srTypeBlocks = [tb] }
            inh = weHierarchy (buildWorkspaceEnv [sf])
        in Map.lookup "DW_Main" inh @?= Just "datawindow"

    , testCase "backtick ancestor ref resolves to the class part, not the raw compound string (w_misth_fylo_form.srw's page1 shape)" $
        let tb  = TypeBlock (mkTypeDecl "page1" "w_form_tab2`page1" (Just "tab1")) []
            sf  = emptyFile { srTypeBlocks = [tb] }
            inh = weHierarchy (buildWorkspaceEnv [sf])
        in Map.lookup "page1" inh @?= Just "w_form_tab2"

    , testCase "multiple files merged" $
        let sf1 = emptyFile { srTypeBlocks = [ TypeBlock (mkTypeDecl "w_a" "w_b" Nothing) [] ] }
            sf2 = emptyFile { srTypeBlocks = [ TypeBlock (mkTypeDecl "w_c" "w_d" Nothing) [] ] }
            inh = weHierarchy (buildWorkspaceEnv [sf1, sf2])
        in (Map.lookup "w_a" inh, Map.lookup "w_c" inh) @?= (Just "w_b", Just "w_d")
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

    , testCase "user-defined type with no span available mints a Synthetic ident" $
        case parseTypeText "w_main" of
          PtUserDefined i -> case identSpan i of
            Synthetic _  -> pure ()
            FromSource _ -> assertFailure "expected Synthetic provenance, got FromSource"
          other -> assertFailure ("expected PtUserDefined, got " ++ show other)
    ]

  , testGroup "parseTypeTextAt"
    [ testCase "user-defined type gets a real FromSource span from the given token" $
        case parseTypeTextAt (SourceSpan 3 5 3 11) "w_main" of
          PtUserDefined i -> identSpan i @?= FromSource (SourceSpan 3 5 3 11 :| [])
          other -> assertFailure ("expected PtUserDefined, got " ++ show other)

    , testCase "primitive type ignores the given span (not identifier-shaped)" $
        parseTypeTextAt (SourceSpan 3 5 3 11) "integer" @?= PtPrimitive "integer"
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
                      , fwdInstances = [GlobalInstance "menu" (SourceSpan 1 1 1 1) "m_item"] }) }
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

  , testGroup "weGlobals forward instances"
    [ testCase "forward global instances are included" $
        let sf = emptyFile
                  { srForward = Just (ForwardBlock
                      { fwdTypes = []
                      , fwdInstances = [GlobalInstance "integer" (SourceSpan 1 1 1 1) "m_main"] }) }
            globals = weGlobals (buildWorkspaceEnv [sf])
        in Map.lookup "m_main" globals @?= Just (PtPrimitive "integer")
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

    , testCase "'super' preserves the ancestor Ident's own real span, not a re-synthesized one" $
        let ancestorIdent = mkIdentAt (SourceSpan 7 1 7 8) "w_parent"
            env = ScopedTypeEnv
              { steLocal = Map.empty, steInstance = Map.empty, steGlobal = Map.empty
              , steHierarchy = Map.singleton (mkIdent "w_child") ancestorIdent
              , steObject = "w_child", steControlIndex = Map.empty, steParams = Set.empty, steParamIndex = Map.empty
              }
        in case lookupScopedVarOrSelf "super" env of
          Just (PtUserDefined i) -> identSpan i @?= FromSource (SourceSpan 7 1 7 8 :| [])
          other -> assertFailure ("expected Just (PtUserDefined ...), got " ++ show other)

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

  , testGroup "extractTypeDecls backtick handling (via ancestorChain)"
    [ testCase "ancestorChain walk continues through a backtick-declared intermediate type" $
        let tbPage = TypeBlock (mkTypeDecl "page1" "w_form_tab2`page1" (Just "tab1")) []
            tbBase = TypeBlock (mkTypeDecl "w_form_tab2" "window" Nothing) []
            sf  = emptyFile { srTypeBlocks = [tbPage, tbBase] }
            inh = weHierarchy (buildWorkspaceEnv [sf])
        in ancestorChain "page1" inh @?= ["page1", "w_form_tab2", "window"]
    ]
  ]
