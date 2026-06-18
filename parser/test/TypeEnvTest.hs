module TypeEnvTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt      (BodyStmt (..), IfStmt (..), ElseIf (..))
import PB.AST.Expr           (Expr (..))
import PB.AST.Located        (Located (..))
import PB.AST.SourceFile     (SrFile (..), FunctionBlock (..), FnSig (..),
                              ForwardBlock (..), TypeDecl (..), TypeBlock (..))
import PB.AST.Type           (PbType (..), parseTypeText)
import PB.Pipeline.TypeEnv   (TypeEnv (..), buildWorkspaceTypeEnv, lookupVarType, lookupUserType)

import Test.Tasty            (TestTree, testGroup)
import Test.Tasty.HUnit      (testCase, (@?=), (@?))

emptyFile :: SrFile
emptyFile = SrFile [] Nothing Nothing Nothing [] [] [] [] [] []

loc1 :: a -> Located a
loc1 = Located 1

tests :: TestTree
tests = testGroup "TypeEnv"
  [ testGroup "buildWorkspaceTypeEnv"
    [ testCase "empty file produces empty env" $
        let env = buildWorkspaceTypeEnv [emptyFile]
        in lookupVarType "x" env @?= Nothing

    , testCase "local var in function body is extracted" $
        let stmt = loc1 (BsLocalVar [] (PtPrimitive "integer") "i_count" Nothing)
            fn = FunctionBlock
              { fbSig = FnSig [] "none" "wf_init" "" Nothing
              , fbBody = [stmt]
              }
            sf = emptyFile { srFunctions = [fn] }
            env = buildWorkspaceTypeEnv [sf]
        in lookupVarType "i_count" env @?= Just (PtPrimitive "integer")

    , testCase "local var with initializer is extracted" $
        let stmt = loc1 (BsLocalVar [] (PtPrimitive "long") "ll_row" (Just (ExInt "0")))
            fn = FunctionBlock
              { fbSig = FnSig [] "none" "wf_test" "" Nothing
              , fbBody = [stmt]
              }
            sf = emptyFile { srFunctions = [fn] }
            env = buildWorkspaceTypeEnv [sf]
        in lookupVarType "ll_row" env @?= Just (PtPrimitive "long")

    , testCase "user-defined type is extracted" $
        let stmt = loc1 (BsLocalVar [] (PtUserDefined "n_cst_service") "svc" Nothing)
            fn = FunctionBlock
              { fbSig = FnSig [] "none" "wf_test" "" Nothing
              , fbBody = [stmt]
              }
            sf = emptyFile { srFunctions = [fn] }
            env = buildWorkspaceTypeEnv [sf]
        in lookupVarType "svc" env @?= Just (PtUserDefined "n_cst_service")

    , testCase "any type is extracted" $
        let stmt = loc1 (BsLocalVar [] PtAny "ax" Nothing)
            fn = FunctionBlock
              { fbSig = FnSig [] "none" "wf_test" "" Nothing
              , fbBody = [stmt]
              }
            sf = emptyFile { srFunctions = [fn] }
            env = buildWorkspaceTypeEnv [sf]
        in lookupVarType "ax" env @?= Just PtAny

    , testCase "decimal with precision is extracted" $
        let stmt = loc1 (BsLocalVar [] (PtDecimalPrec 10) "lc_val" Nothing)
            fn = FunctionBlock
              { fbSig = FnSig [] "none" "wf_test" "" Nothing
              , fbBody = [stmt]
              }
            sf = emptyFile { srFunctions = [fn] }
            env = buildWorkspaceTypeEnv [sf]
        in lookupVarType "lc_val" env @?= Just (PtDecimalPrec 10)

    , testCase "vars inside if-then are extracted" $
        let innerStmt = loc1 (BsLocalVar [] (PtPrimitive "string") "ls_name" Nothing)
            ifStmt = loc1 (BsIf (IfStmt (ExBool True) [innerStmt] [] Nothing))
            fn = FunctionBlock
              { fbSig = FnSig [] "none" "wf_test" "" Nothing
              , fbBody = [ifStmt]
              }
            sf = emptyFile { srFunctions = [fn] }
            env = buildWorkspaceTypeEnv [sf]
        in lookupVarType "ls_name" env @?= Just (PtPrimitive "string")
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
  ]
