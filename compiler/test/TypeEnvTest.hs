module TypeEnvTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt       (BodyStmt (..))
import PB.AST.Located        (Located (..))
import PB.AST.SourceFile     (SrFile (..), ForwardBlock (..), TypeDecl (..), TypeBlock (..),
                              GlobalInstance (..), srAllTypeDecls, srPrimaryObject)
import PB.AST.Type           (PbType (..), parseTypeText)
import PB.Analysis.TypeEnv   (TypeEnv (..), buildWorkspaceTypeEnv, lookupVarType, lookupUserType,
                              lookupBaseType, isDescendantOf,
                              ScopedTypeEnv (..), buildWorkspaceEnv,
                              procEnv, lookupScopedVar)
import PB.Analysis.TypeResolve (buildObjectSet, buildUserTypeSet)

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import Test.Tasty            (TestTree, testGroup)
import Test.Tasty.HUnit      (testCase, (@?=))

emptyFile :: SrFile
emptyFile = SrFile [] Nothing Nothing Nothing [] [] [] [] [] []

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
                      { fwdTypes = [TypeDecl "w_foo" "window" Nothing]
                      , fwdInstances = []
                      })}
            env = buildWorkspaceTypeEnv [sf]
        in lookupUserType "w_foo" env @?= Just "window"

    , testCase "type decl from type block is found" $
        let tb = TypeBlock (TypeDecl "nvo_utils" "nonvisualobject" Nothing) []
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
                      { fwdTypes = [TypeDecl "u_st" "pfc_u_st" Nothing]
                      , fwdInstances = [] })}
        in srPrimaryObject sf @?= ("u_st", Just "pfc_u_st")

    , testCase "type block wins over forward block" $
        let sf = emptyFile
                  { srForward = Just (ForwardBlock
                      { fwdTypes = [TypeDecl "u_st" "pfc_u_st" Nothing]
                      , fwdInstances = [] })
                  , srTypeBlocks = [TypeBlock (TypeDecl "u_st" "window" Nothing) []] }
        in srPrimaryObject sf @?= ("u_st", Just "window")

    , testCase "empty file returns empty" $
        srPrimaryObject emptyFile @?= ("", Nothing)

    , testCase "forward block with no types returns empty" $
        let sf = emptyFile
                  { srForward = Just (ForwardBlock
                      { fwdTypes = []
                      , fwdInstances = [GlobalInstance "menu" "m_item"] }) }
        in srPrimaryObject sf @?= ("", Nothing)
    ]

  , testGroup "srAllTypeDecls"
    [ testCase "merges type blocks and forward block" $
        let sf = emptyFile
                  { srTypeBlocks = [TypeBlock (TypeDecl "w_main" "window" Nothing) []]
                  , srForward = Just (ForwardBlock
                      { fwdTypes = [TypeDecl "u_st" "pfc_u_st" Nothing]
                      , fwdInstances = [] }) }
            decls = srAllTypeDecls sf
        in length decls @?= 2

    , testCase "forward block only" $
        let sf = emptyFile
                  { srForward = Just (ForwardBlock
                      { fwdTypes = [TypeDecl "u_st" "pfc_u_st" Nothing]
                      , fwdInstances = [] }) }
        in length (srAllTypeDecls sf) @?= 1

    , testCase "type blocks only" $
        let sf = emptyFile
                  { srTypeBlocks = [TypeBlock (TypeDecl "w_main" "window" Nothing) []] }
        in length (srAllTypeDecls sf) @?= 1
    ]

  , testGroup "buildObjectSet"
    [ testCase "forward-only non-structure type is included" $
        let sf = emptyFile
                  { srForward = Just (ForwardBlock
                      { fwdTypes = [TypeDecl "u_st" "pfc_u_st" Nothing]
                      , fwdInstances = [] }) }
        in Set.member "u_st" (buildObjectSet [sf]) @?= True

    , testCase "forward-only structure type is excluded" $
        let sf = emptyFile
                  { srForward = Just (ForwardBlock
                      { fwdTypes = [TypeDecl "s_data" "structure" Nothing]
                      , fwdInstances = [] }) }
        in Set.member "s_data" (buildObjectSet [sf]) @?= False
    ]

  , testGroup "buildUserTypeSet"
    [ testCase "forward-only structure type is included" $
        let sf = emptyFile
                  { srForward = Just (ForwardBlock
                      { fwdTypes = [TypeDecl "s_data" "structure" Nothing]
                      , fwdInstances = [] }) }
        in Set.member "s_data" (buildUserTypeSet [sf]) @?= True

    , testCase "forward-only non-structure type is excluded" $
        let sf = emptyFile
                  { srForward = Just (ForwardBlock
                      { fwdTypes = [TypeDecl "u_st" "pfc_u_st" Nothing]
                      , fwdInstances = [] }) }
        in Set.member "u_st" (buildUserTypeSet [sf]) @?= False
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
              }
        in lookupScopedVar "x" env @?= Just (PtPrimitive "string")

    , testCase "lookupScopedVar finds instance, shadowing global" $
        let env = ScopedTypeEnv
              { steLocal    = Map.empty
              , steInstance = Map.singleton "y" (PtPrimitive "long")
              , steGlobal   = Map.singleton "y" (PtPrimitive "integer")
              , steHierarchy = Map.empty
              }
        in lookupScopedVar "y" env @?= Just (PtPrimitive "long")

    , testCase "lookupScopedVar falls through to global" $
        let env = ScopedTypeEnv
              { steLocal    = Map.empty
              , steInstance = Map.empty
              , steGlobal   = Map.singleton "z" (PtPrimitive "boolean")
              , steHierarchy = Map.empty
              }
        in lookupScopedVar "z" env @?= Just (PtPrimitive "boolean")

    , testCase "lookupScopedVar is case-insensitive" $
        let env = ScopedTypeEnv
              { steLocal    = Map.singleton "foo" (PtPrimitive "string")
              , steInstance = Map.empty
              , steGlobal   = Map.empty
              , steHierarchy = Map.empty
              }
        in lookupScopedVar "FOO" env @?= Just (PtPrimitive "string")

    , testCase "procEnv wires correct instance layer for obj_a" $
        let sfA = emptyFile
              { srTypeBlocks = [TypeBlock (TypeDecl "obj_a" "window" Nothing)
                  [Located 1 (BsLocalVar [] (PtPrimitive "integer") "foo" Nothing)]] }
            sfB = emptyFile
              { srTypeBlocks = [TypeBlock (TypeDecl "obj_b" "window" Nothing)
                  [Located 1 (BsLocalVar [] (PtPrimitive "string") "foo" Nothing)]] }
            ws  = buildWorkspaceEnv [sfA, sfB]
        in lookupScopedVar "foo" (procEnv ws "obj_a" []) @?= Just (PtPrimitive "integer")

    , testCase "procEnv wires correct instance layer for obj_b" $
        let sfA = emptyFile
              { srTypeBlocks = [TypeBlock (TypeDecl "obj_a" "window" Nothing)
                  [Located 1 (BsLocalVar [] (PtPrimitive "integer") "foo" Nothing)]] }
            sfB = emptyFile
              { srTypeBlocks = [TypeBlock (TypeDecl "obj_b" "window" Nothing)
                  [Located 1 (BsLocalVar [] (PtPrimitive "string") "foo" Nothing)]] }
            ws  = buildWorkspaceEnv [sfA, sfB]
        in lookupScopedVar "foo" (procEnv ws "obj_b" []) @?= Just (PtPrimitive "string")

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
  ]
