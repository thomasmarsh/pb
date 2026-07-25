module DwParamBindingTest (tests) where

import Prelude
import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit ((@?=), testCase)

import qualified Data.Map.Strict as Map
import qualified Data.Text       as T

import PB.AST.BodyStmt
import PB.AST.Expr
import PB.AST.Ident        (mkIdent)
import PB.AST.Located      (Located (..))
import PB.AST.SourceFile
import PB.AST.Type         (PbType (..))
import PB.Lexing.Token     (SourceSpan (..))
import PB.Analysis.ControlHierarchy (buildControlIndex)
import PB.Analysis.TypeResolve (buildProcMap)
import PB.Analysis.TypeEnv (buildWorkspaceEnv, weHierarchy)
import PB.Analysis.TypeCheck (buildParamsMap)
import PB.Analysis.DwParamBinding (buildDwParamBindings)

-- ---------------------------------------------------------------------------
-- Helpers (mirrors TypeResolveTest.hs's fixture-construction style)

emptySrFile :: SrFile
emptySrFile = SrFile
  { srHeaders         = []
  , srForward         = Nothing
  , srPrototypes      = Nothing
  , srVariables       = []
  , srGlobalInstances = []
  , srTypeBlocks      = []
  , srOnBlocks        = []
  , srEvents          = []
  , srFunctions       = []
  , srSubroutines     = []
  }

mkTB :: T.Text -> T.Text -> TypeBlock
mkTB nm anc = TypeBlock { tbDecl = mkTypeDecl nm anc Nothing, tbBody = [] }

dwControlTB :: T.Text -> Maybe T.Text -> Maybe T.Text -> TypeBlock
dwControlTB nm within dwName = TypeBlock
  { tbDecl = mkTypeDecl nm "datawindow" within
  , tbBody = case dwName of
      Just dw -> [ Located 1 (BsLocalVar [] (PtPrimitive "string") "dataobject" (Just (ExStr dw))) ]
      Nothing -> []
  }

-- | Test-only fixture helper: parses a simple comma-separated "[mods] type
-- name" list into synthetic-span 'Param's -- mirrors TypeResolveTest.hs's
-- own copy. Fixture construction only; the real token-level parser is
-- tested directly in FileTest.hs.
mkParams :: T.Text -> [Param]
mkParams raw
  | T.null (T.strip raw) = []
  | otherwise            = map paramFor (T.splitOn "," raw)
  where
    mods = ["ref", "readonly", "constant", "static", "indirect"]
    paramFor seg = case dropWhile (\w -> T.toLower w `elem` mods) (T.words (T.strip seg)) of
      [ty, nm] -> Param [] ty (SourceSpan 1 1 1 1) (mkIdent nm)
      ws       -> error ("mkParams: malformed test fixture segment " ++ show ws)

mkFn :: T.Text -> T.Text -> [Located BodyStmt] -> FunctionBlock
mkFn nm params body = FunctionBlock
  { fbSig = FnSig { fnsMods = [], fnsReturnType = "integer", fnsReturnTypeSpan = SourceSpan 1 1 1 1
                  , fnsName = mkIdent nm, fnsParams = mkParams params, fnsThrows = Nothing
                  , fnsLibrary = Nothing, fnsAliasFor = Nothing }
  , fbBody = body
  }

mkSub :: T.Text -> T.Text -> [Located BodyStmt] -> SubroutineBlock
mkSub nm params body = SubroutineBlock
  { sbSig = SubSig { ssMods = [], ssName = mkIdent nm, ssParams = mkParams params, ssThrows = Nothing
                    , ssLibrary = Nothing, ssAliasFor = Nothing }
  , sbBody = body
  }

callStmt :: T.Text -> [Expr] -> Located BodyStmt
callStmt calleeName args = Located 5 (BsCall (ExCall
  { callee = Lvalue [LvSegment (mkIdent calleeName) Nothing], callArgs = args }))

lvArg :: T.Text -> Expr
lvArg n = ExLvalue (Lvalue [LvSegment (mkIdent n) Nothing])

runBuild :: [SrFile] -> Map.Map (T.Text, T.Text, Int) T.Text
runBuild sfs = buildDwParamBindings (buildProcMap sfs) (weHierarchy (buildWorkspaceEnv sfs)) (buildParamsMap sfs) (buildControlIndex sfs) sfs

-- ---------------------------------------------------------------------------

tests :: TestTree
tests = testGroup "DwParamBinding"
  [ testGroup "buildDwParamBindings"
      [ testCase "a single caller passing a literal-bound DW control resolves the parameter's binding" $ do
          let sf = emptySrFile
                { srTypeBlocks =
                    [ mkTB "u_grid" "userobject"
                    , dwControlTB "dw_main" (Just "u_grid") (Just "d_test")
                    ]
                , srSubroutines = [ mkSub "of_postinitrow" "ref datawindow adw, long row" [] ]
                , srFunctions   = [ mkFn "f_caller" "" [ callStmt "of_postinitrow" [lvArg "dw_main", ExInt "1"] ] ]
                }
          runBuild [sf] @?= Map.singleton ("u_grid", "of_postinitrow", 0) "d_test"

      , testCase "two callers passing different literal DWs at the same position -> ambiguous, no binding" $ do
          let sf = emptySrFile
                { srTypeBlocks =
                    [ mkTB "u_grid" "userobject"
                    , dwControlTB "dw_a" (Just "u_grid") (Just "d_a")
                    , dwControlTB "dw_b" (Just "u_grid") (Just "d_b")
                    ]
                , srSubroutines = [ mkSub "of_postinitrow" "ref datawindow adw, long row" [] ]
                , srFunctions   =
                    [ mkFn "f_caller1" "" [ callStmt "of_postinitrow" [lvArg "dw_a", ExInt "1"] ]
                    , mkFn "f_caller2" "" [ callStmt "of_postinitrow" [lvArg "dw_b", ExInt "1"] ]
                    ]
                }
          runBuild [sf] @?= Map.empty

      , testCase "two callers agreeing on the same literal DW resolve it (not treated as ambiguous)" $ do
          let sf = emptySrFile
                { srTypeBlocks =
                    [ mkTB "u_grid" "userobject"
                    , dwControlTB "dw_a" (Just "u_grid") (Just "d_test")
                    , dwControlTB "dw_b" (Just "u_grid") (Just "d_test")
                    ]
                , srSubroutines = [ mkSub "of_postinitrow" "ref datawindow adw, long row" [] ]
                , srFunctions   =
                    [ mkFn "f_caller1" "" [ callStmt "of_postinitrow" [lvArg "dw_a", ExInt "1"] ]
                    , mkFn "f_caller2" "" [ callStmt "of_postinitrow" [lvArg "dw_b", ExInt "1"] ]
                    ]
                }
          runBuild [sf] @?= Map.singleton ("u_grid", "of_postinitrow", 0) "d_test"

      , testCase "a non-DataWindow-typed parameter position never gets a binding" $ do
          let sf = emptySrFile
                { srTypeBlocks  = [ mkTB "u_grid" "userobject", dwControlTB "dw_main" (Just "u_grid") (Just "d_test") ]
                , srSubroutines = [ mkSub "of_go" "long al_row" [] ]
                , srFunctions   = [ mkFn "f_caller" "" [ callStmt "of_go" [lvArg "dw_main"] ] ]
                }
          runBuild [sf] @?= Map.empty

      , testCase "a caller passing an unbound control (no static dataobject) contributes no candidate" $ do
          let sf = emptySrFile
                { srTypeBlocks  = [ mkTB "u_grid" "userobject", dwControlTB "dw_main" (Just "u_grid") Nothing ]
                , srSubroutines = [ mkSub "of_postinitrow" "ref datawindow adw, long row" [] ]
                , srFunctions   = [ mkFn "f_caller" "" [ callStmt "of_postinitrow" [lvArg "dw_main", ExInt "1"] ] ]
                }
          runBuild [sf] @?= Map.empty
      ]
  ]
