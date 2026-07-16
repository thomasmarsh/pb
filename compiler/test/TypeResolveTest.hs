module TypeResolveTest (tests) where

import Prelude
import Test.Tasty         (TestTree, testGroup)
import Test.Tasty.HUnit   ((@?=), assertFailure, testCase)

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T

import PB.AST.BodyStmt
import PB.AST.Expr
import PB.AST.Located      (Located (..))
import PB.AST.SourceFile
import PB.AST.Type         (PbType (..))
import PB.Grammar.DataWindow (parseDataWindow)
import PB.Analysis.TypeResolve

-- ---------------------------------------------------------------------------
-- Helpers

emptySrFile :: SrFile
emptySrFile = SrFile
  { srHeaders         = []
  , srForward         = Nothing
  , srPrototypes      = Nothing
  , srVariables       = Nothing
  , srGlobalInstances = []
  , srTypeBlocks      = []
  , srOnBlocks        = []
  , srEvents          = []
  , srFunctions       = []
  , srSubroutines     = []
  }

mkTB :: T.Text -> T.Text -> TypeBlock
mkTB nm anc = TypeBlock
  { tbDecl = TypeDecl { tdName = nm, tdAncestor = anc, tdWithin = Nothing }
  , tbBody = []
  }

mkFn :: T.Text -> T.Text -> [Located BodyStmt] -> FunctionBlock
mkFn nm params body = FunctionBlock
  { fbSig = FnSig
      { fnsMods       = []
      , fnsReturnType = "integer"
      , fnsName       = nm
      , fnsParams     = params
      , fnsThrows     = Nothing
      }
  , fbBody = body
  }

localVarStmt :: T.Text -> PbType -> Int -> Located BodyStmt
localVarStmt nm ty line = Located line BsLocalVar
  { varMods = []
  , varType = ty
  , varName = nm
  , varInit = Nothing
  }

callStmt :: T.Text -> Int -> Located BodyStmt
callStmt callee_ line = Located line
  (BsCall (ExCall
    { callee   = Lvalue [LvSegment callee_ Nothing]
    , callArgs = []
    }))

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "TypeResolve"
  [ testGroup "classifyPbType"
      [ testCase "PtPrimitive string → primitive" $ do
          let (k, t) = classifyPbType (PtPrimitive "string") Set.empty Set.empty
          k @?= "primitive"
          t @?= Nothing

      , testCase "PtAny → any" $ do
          let (k, t) = classifyPbType PtAny Set.empty Set.empty
          k @?= "any"
          t @?= Nothing

      , testCase "PtDecimalPrec → primitive" $ do
          let (k, t) = classifyPbType (PtDecimalPrec 10) Set.empty Set.empty
          k @?= "primitive"
          t @?= Nothing

      , testCase "PtUserDefined in object set → object" $ do
          let (k, t) = classifyPbType (PtUserDefined "w_main")
                         (Set.singleton "w_main") Set.empty
          k @?= "object"
          t @?= Just "w_main"

      , testCase "PtUserDefined in user type set → user_type" $ do
          let (k, t) = classifyPbType (PtUserDefined "n_cst_service")
                         Set.empty (Set.singleton "n_cst_service")
          k @?= "user_type"
          t @?= Just "n_cst_service"

      , testCase "PtUserDefined datawindow → primitive" $ do
          let (k, t) = classifyPbType (PtUserDefined "datawindow") Set.empty Set.empty
          k @?= "primitive"
          t @?= Nothing

      , testCase "PtUserDefined Window mixed-case → primitive" $ do
          let (k, t) = classifyPbType (PtUserDefined "Window") Set.empty Set.empty
          k @?= "primitive"
          t @?= Nothing

      , testCase "PtUserDefined xyz_unknown → unresolved" $ do
          let (k, t) = classifyPbType (PtUserDefined "xyz_unknown") Set.empty Set.empty
          k @?= "unresolved"
          t @?= Nothing

      , testCase "PtPrimitive datawindow → object (built-in class, not value primitive)" $ do
          let (k, t) = classifyPbType (PtPrimitive "datawindow") Set.empty Set.empty
          k @?= "object"
          t @?= Just "datawindow"

      , testCase "PtPrimitive transaction → object (built-in class)" $ do
          let (k, t) = classifyPbType (PtPrimitive "transaction") Set.empty Set.empty
          k @?= "object"
          t @?= Just "transaction"
      ]

  , testGroup "parseParams"
      [ testCase "empty string → []" $
          parseParams "" @?= []

      , testCase "whitespace only → []" $
          parseParams "   " @?= []

      , testCase "single param: long al_row" $
          parseParams "long al_row"
            @?= [("al_row", PtPrimitive "long")]

      , testCase "ref param stripped: ref datawindow adw" $
          parseParams "ref datawindow adw"
            @?= [("adw", PtUserDefined "datawindow")]

      , testCase "two params" $
          parseParams "long al_row, string as_name"
            @?= [("al_row", PtPrimitive "long"), ("as_name", PtPrimitive "string")]

      , testCase "readonly modifier stripped" $
          parseParams "readonly string as_x"
            @?= [("as_x", PtPrimitive "string")]

      , testCase "array-bracket param name: readonly string aarray[]" $
          -- Reproduces the exact reconstructed-text shape parseParamsAndThrows
          -- produces (File.hs:184 joins tokens with " ", and '[' / ']' are
          -- separate tokens), not a hand-written unbracketed string.
          parseParams "readonly string aarray [ ]"
            @?= [("aarray", PtPrimitive "string")]

      , testCase "array-bracket param alongside a normal param" $
          parseParams "readonly string aarray [ ] , string astr"
            @?= [("aarray", PtPrimitive "string"), ("astr", PtPrimitive "string")]
      ]

  , testGroup "extractLocalVars"
      [ testCase "empty SrFile → []" $
          extractLocalVars "test.srw" "w_test" emptySrFile @?= []

      , testCase "BsLocalVar from function body" $ do
          let body = [ localVarStmt "ls_x" (PtPrimitive "string") 10 ]
              sf   = emptySrFile { srFunctions = [ mkFn "f_go" "" body ] }
          case extractLocalVars "test.srw" "w_test" sf of
            [v] -> do
              lvVarName   v @?= "ls_x"
              lvRawType   v @?= "string"
              lvIsParam   v @?= False
              lvScopeLine v @?= 10
            other -> assertFailure ("expected 1 var, got " ++ show (length other))

      , testCase "BsLocalVar nested inside if block" $ do
          let inner = [ localVarStmt "li_x" (PtPrimitive "integer") 20 ]
              stmt  = Located 15 (BsIf IfStmt
                { ifCond    = ExBool True
                , ifThen    = inner
                , ifElseIfs = []
                , ifElse    = Nothing
                })
              sf = emptySrFile { srFunctions = [ mkFn "f_go" "" [stmt] ] }
          case extractLocalVars "test.srw" "w_test" sf of
            [v] -> lvVarName v @?= "li_x"
            other -> assertFailure ("expected 1 var, got " ++ show (length other))

      , testCase "function params from FnSig text" $ do
          let sf = emptySrFile { srFunctions = [ mkFn "f_go" "long al_row, string as_x" [] ] }
          case extractLocalVars "test.srw" "w_test" sf of
            [a, b] -> do
              lvIsParam a @?= True
              lvVarName a @?= "al_row"
              lvIsParam b @?= True
              lvVarName b @?= "as_x"
            other -> assertFailure ("expected 2 vars, got " ++ show (length other))

      , testCase "params before body vars" $ do
          let body = [ localVarStmt "ls_x" (PtPrimitive "string") 5 ]
              sf   = emptySrFile { srFunctions = [ mkFn "f_go" "long al_row" body ] }
          case extractLocalVars "test.srw" "w_test" sf of
            [a, b] -> do
              lvIsParam a @?= True
              lvIsParam b @?= False
            other -> assertFailure ("expected 2 vars, got " ++ show (length other))
      ]

  , testGroup "extractCallSites"
      [ testCase "empty SrFile → []" $
          extractCallSites "test.srw" "w_test" emptySrFile @?= []

      , testCase "ExCall from BsCall" $ do
          let body  = [ callStmt "f_helper" 5 ]
              sf    = emptySrFile { srFunctions = [ mkFn "f_go" "" body ] }
          case extractCallSites "test.srw" "w_test" sf of
            [s] -> do
              csToName   s @?= "f_helper"
              csCallType s @?= "ExCall"
              csLine     s @?= Just 5
            other -> assertFailure ("expected 1 site, got " ++ show (length other))

      , testCase "ExMethodCall from BsCall" $ do
          let body = [ Located 7
                  (BsCall (ExMethodCall
                    { receiver   = ExLvalue (Lvalue [LvSegment "dw_1" Nothing])
                    , method     = "retrieve"
                    , methodArgs = []
                    })) ]
              sf = emptySrFile { srFunctions = [ mkFn "f_go" "" body ] }
          case extractCallSites "test.srw" "w_test" sf of
            [s] -> do
              csToName   s @?= "retrieve"
              csCallType s @?= "ExMethodCall"
            other -> assertFailure ("expected 1 site, got " ++ show (length other))

      , testCase "calls extracted from nested if body" $ do
          let inner = [ callStmt "f_inner" 30 ]
              body  = [ Located 25
                  (BsIf IfStmt
                    { ifCond    = ExBool True
                    , ifThen    = inner
                    , ifElseIfs = []
                    , ifElse    = Nothing
                    }) ]
              sf = emptySrFile { srFunctions = [ mkFn "f_go" "" body ] }
          case extractCallSites "test.srw" "w_test" sf of
            [s] -> csToName s @?= "f_inner"
            other -> assertFailure ("expected 1 site, got " ++ show (length other))

      , testCase "calls extracted from if condition" $ do
          let cond = ExCall
                { callee   = Lvalue [LvSegment "of_checkdelete" Nothing]
                , callArgs = []
                }
              body = [ Located 10
                  (BsIf IfStmt
                    { ifCond    = ExNot cond
                    , ifThen    = []
                    , ifElseIfs = []
                    , ifElse    = Nothing
                    }) ]
              sf = emptySrFile { srFunctions = [ mkFn "clicked" "" body ] }
          case extractCallSites "test.srw" "w_test" sf of
            [s] -> csToName s @?= "of_checkdelete"
            other -> assertFailure ("expected 1 site, got " ++ show (length other))
      ]

  , testGroup "buildInheritsMap"
      [ testCase "builds from srTypeBlocks" $ do
          let sf = emptySrFile { srTypeBlocks = [ mkTB "w_child" "w_parent" ] }
          Map.lookup "w_child" (buildInheritsMap [sf]) @?= Just "w_parent"

      , testCase "multiple files merged" $ do
          let sf1 = emptySrFile { srTypeBlocks = [ mkTB "w_a" "w_b" ] }
              sf2 = emptySrFile { srTypeBlocks = [ mkTB "w_c" "w_d" ] }
              m   = buildInheritsMap [sf1, sf2]
          Map.lookup "w_a" m @?= Just "w_b"
          Map.lookup "w_c" m @?= Just "w_d"

      , testCase "backtick ancestor ref resolves to the class part, not the raw compound string (w_misth_fylo_form.srw's page1 shape)" $ do
          let sf = emptySrFile { srTypeBlocks = [ mkTB "page1" "w_form_tab2`page1" ] }
          Map.lookup "page1" (buildInheritsMap [sf]) @?= Just "w_form_tab2"
      ]

  , testGroup "buildProcMap"
      [ testCase "includes function names" $ do
          let sf = emptySrFile
                { srTypeBlocks = [ mkTB "w_test" "window" ]
                , srFunctions  = [ mkFn "f_go" "" [] ]
                }
              pm = buildProcMap [sf]
          Set.member "f_go" (Map.findWithDefault Set.empty "w_test" pm) @?= True
      ]

  , testGroup "resolveTypes"
      [ testCase "primitive local var → primitive kind" $ do
          let lv = LocalVar
                { lvFile      = "t.srw"
                , lvObject    = "w_t"
                , lvProcName  = "f"
                , lvVarName   = "ls_x"
                , lvRawType   = "string"
                , lvIsParam   = False
                , lvScopeLine = 1
                , lvPbType    = PtPrimitive "string"
                }
          case resolveTypes [lv] Set.empty Set.empty of
            [rt] -> do
              rtKind rt   @?= "primitive"
              rtTarget rt @?= Nothing
            other -> assertFailure ("expected 1 result, got " ++ show (length other))

      , testCase "object local var → object kind with target" $ do
          let lv = LocalVar
                { lvFile      = "t.srw"
                , lvObject    = "w_t"
                , lvProcName  = "f"
                , lvVarName   = "lw_win"
                , lvRawType   = "w_main"
                , lvIsParam   = False
                , lvScopeLine = 2
                , lvPbType    = PtUserDefined "w_main"
                }
          case resolveTypes [lv] (Set.singleton "w_main") Set.empty of
            [rt] -> do
              rtKind rt   @?= "object"
              rtTarget rt @?= Just "w_main"
            other -> assertFailure ("expected 1 result, got " ++ show (length other))
      ]

  , testGroup "resolveCalls"
      [ testCase "bare call to own proc → virtual high" $ do
          let site = CallSite
                { csFile     = "t.srw"
                , csObject   = "w_t"
                , csFromProc = "f_go"
                , csToName   = "f_helper"
                , csCallType = "ExCall"
                , csLine     = Just 5
                }
              pm = Map.singleton "w_t" (Set.singleton "f_helper")
          case resolveCalls [site] pm Map.empty Set.empty Set.empty of
            [rc] -> do
              rcKind rc         @?= "virtual"
              rcConfidence rc   @?= "high"
              rcTargetObject rc @?= Just "w_t"
              rcTargetProc   rc @?= Just "f_helper"
            other -> assertFailure ("expected 1 result, got " ++ show (length other))

      , testCase "bare call to ancestor proc → inherited high" $ do
          let site = CallSite
                { csFile     = "t.srw"
                , csObject   = "w_child"
                , csFromProc = "f_go"
                , csToName   = "f_base"
                , csCallType = "ExCall"
                , csLine     = Nothing
                }
              pm  = Map.fromList
                      [ ("w_child",  Set.empty)
                      , ("w_parent", Set.singleton "f_base")
                      ]
              inh = Map.singleton "w_child" "w_parent"
          case resolveCalls [site] pm inh Set.empty Set.empty of
            [rc] -> do
              rcKind rc         @?= "inherited"
              rcTargetObject rc @?= Just "w_parent"
            other -> assertFailure ("expected 1 result, got " ++ show (length other))

      , testCase "bare call not found → unresolved low" $ do
          let site = CallSite
                { csFile     = "t.srw"
                , csObject   = "w_t"
                , csFromProc = "f_go"
                , csToName   = "f_ghost"
                , csCallType = "ExCall"
                , csLine     = Nothing
                }
          case resolveCalls [site] Map.empty Map.empty Set.empty Set.empty of
            [rc] -> do
              rcKind rc       @?= "unresolved"
              rcConfidence rc @?= "low"
            other -> assertFailure ("expected 1 result, got " ++ show (length other))

      , testCase "bare call to unique global proc → virtual high (global fallback)" $ do
          -- trn() is a standalone function in a separate object; the caller's ancestor
          -- chain doesn't include 'trn', but the global fallback resolves it uniquely.
          let site = CallSite
                { csFile     = "w_main.srw"
                , csObject   = "w_main"
                , csFromProc = "open"
                , csToName   = "trn"
                , csCallType = "ExCall"
                , csLine     = Just 10
                }
              pm = Map.fromList
                     [ ("w_main", Set.empty)
                     , ("trn",    Set.singleton "trn")
                     ]
          case resolveCalls [site] pm Map.empty Set.empty Set.empty of
            [rc] -> do
              rcKind rc         @?= "virtual"
              rcConfidence rc   @?= "high"
              rcTargetObject rc @?= Just "trn"
              rcTargetProc   rc @?= Just "trn"
            other -> assertFailure ("expected 1 result, got " ++ show (length other))

      , testCase "bare call to ambiguous global name → unresolved" $ do
          -- If multiple objects define f_helper, we can't resolve unambiguously.
          let site = CallSite
                { csFile     = "t.srw"
                , csObject   = "w_t"
                , csFromProc = "f_go"
                , csToName   = "f_helper"
                , csCallType = "ExCall"
                , csLine     = Nothing
                }
              pm = Map.fromList
                     [ ("w_t",     Set.empty)
                     , ("w_other", Set.singleton "f_helper")
                     , ("w_third", Set.singleton "f_helper")
                     ]
          case resolveCalls [site] pm Map.empty Set.empty Set.empty of
            [rc] -> rcKind rc @?= "unresolved"
            other -> assertFailure ("expected 1 result, got " ++ show (length other))

      , testCase "dotted ExCall to known object → static high" $ do
          let site = CallSite
                { csFile     = "t.srw"
                , csObject   = "w_t"
                , csFromProc = "f_go"
                , csToName   = "w_other.f_method"
                , csCallType = "ExCall"
                , csLine     = Nothing
                }
              pm = Map.fromList
                     [ ("w_t",     Set.empty)
                     , ("w_other", Set.singleton "f_method")
                     ]
          case resolveCalls [site] pm Map.empty Set.empty Set.empty of
            [rc] -> do
              rcKind rc         @?= "static"
              rcConfidence rc   @?= "high"
              rcTargetObject rc @?= Just "w_other"
              rcTargetProc   rc @?= Just "f_method"
            other -> assertFailure ("expected 1 result, got " ++ show (length other))

      , testCase "ExMethodCall → unresolved" $ do
          let site = CallSite
                { csFile     = "t.srw"
                , csObject   = "w_t"
                , csFromProc = "f_go"
                , csToName   = "retrieve"
                , csCallType = "ExMethodCall"
                , csLine     = Nothing
                }
          case resolveCalls [site] Map.empty Map.empty Set.empty Set.empty of
            [rc] -> rcKind rc @?= "unresolved"
            other -> assertFailure ("expected 1 result, got " ++ show (length other))
      ]

  , testGroup "resolveCalls/builtin"
      [ testCase "bare ExCall matching free_function_names → builtin high" $ do
          let site = CallSite
                { csFile     = "t.srw"
                , csObject   = "w_t"
                , csFromProc = "f_go"
                , csToName   = "MessageBox"
                , csCallType = "ExCall"
                , csLine     = Nothing
                }
          case resolveCalls [site] Map.empty Map.empty (Set.singleton "messagebox") Set.empty of
            [rc] -> do
              rcKind rc         @?= "builtin"
              rcConfidence rc   @?= "high"
              rcTargetObject rc @?= Nothing
              rcTargetProc   rc @?= Nothing
            other -> assertFailure ("expected 1 result, got " ++ show (length other))

      , testCase "ExMethodCall matching class_methods → builtin high" $ do
          let site = CallSite
                { csFile     = "t.srw"
                , csObject   = "w_t"
                , csFromProc = "f_go"
                , csToName   = "Retrieve"
                , csCallType = "ExMethodCall"
                , csLine     = Nothing
                }
          case resolveCalls [site] Map.empty Map.empty Set.empty (Set.singleton "retrieve") of
            [rc] -> do
              rcKind rc         @?= "builtin"
              rcConfidence rc   @?= "high"
              rcTargetObject rc @?= Nothing
              rcTargetProc   rc @?= Nothing
            other -> assertFailure ("expected 1 result, got " ++ show (length other))

      , testCase "bare ExCall not in builtins falls through to virtual" $ do
          let site = CallSite
                { csFile     = "t.srw"
                , csObject   = "w_t"
                , csFromProc = "f_go"
                , csToName   = "f_helper"
                , csCallType = "ExCall"
                , csLine     = Nothing
                }
              pm = Map.singleton "w_t" (Set.singleton "f_helper")
          case resolveCalls [site] pm Map.empty Set.empty Set.empty of
            [rc] -> rcKind rc @?= "virtual"
            other -> assertFailure ("expected 1 result, got " ++ show (length other))
      ]
  , testGroup "extractDwCallSites"
    [ testCase "empty DW yields no call sites" $ do
        case parseDataWindow dwMin of
          Left err -> assertFailure ("parse error: " <> T.unpack err)
          Right dw -> extractDwCallSites "test.srd" "dw_test" dw @?= []

    , testCase "compute expression ExCall becomes a call site" $ do
        let src = dwMin <> "\ncompute(band=summary name=c1 x=\"0\" y=\"0\" width=\"100\" height=\"40\" visible=\"1\" expression=\"fn_foo()\" )"
        case parseDataWindow src of
          Left err -> assertFailure ("parse error: " <> T.unpack err)
          Right dw -> case extractDwCallSites "test.srd" "dw_test" dw of
            [cs] -> do
              csObject   cs @?= "dw_test"
              csFromProc cs @?= ""
              csToName   cs @?= "fn_foo"
              csCallType cs @?= "ExCall"
              csLine     cs @?= Nothing
            other -> assertFailure ("expected 1 call site, got " <> show (length other))

    , testCase "BinOp expression yields both callee names" $ do
        let src = dwMin <> "\ncompute(band=summary name=c1 x=\"0\" y=\"0\" width=\"100\" height=\"40\" visible=\"1\" expression=\"fn_a( x ) - fn_b( x )\" )"
        case parseDataWindow src of
          Left err -> assertFailure ("parse error: " <> T.unpack err)
          Right dw ->
            let names = map csToName (extractDwCallSites "test.srd" "dw_test" dw)
            in  names @?= ["fn_a", "fn_b"]

    , testCase "format ExCall after ~t separator becomes a call site" $ do
        let src = dwMin <> "\ncompute(band=summary name=c1 x=\"0\" y=\"0\" width=\"100\" height=\"40\" visible=\"1\" expression=\"fn_val()\" format=\"[GENERAL]~tfn_mask()\" )"
        case parseDataWindow src of
          Left err -> assertFailure ("parse error: " <> T.unpack err)
          Right dw ->
            let names = map csToName (extractDwCallSites "test.srd" "dw_test" dw)
            in  names @?= ["fn_val", "fn_mask"]
    ]

  , testGroup "classifyControlType"
    [ testCase "dw_ prefix → datawindow" $
        classifyControlType "dw_orders" @?= Just "datawindow"

    , testCase "cb_ prefix → commandbutton" $
        classifyControlType "cb_ok" @?= Just "commandbutton"

    , testCase "dddw_ matched before dw_" $
        -- dddw_ appears before dw_ in prefix map; must yield datawindowchild not datawindow
        classifyControlType "dddw_status" @?= Just "datawindowchild"

    , testCase "ddlb_ matched before lb_" $
        classifyControlType "ddlb_type" @?= Just "dropdownlistbox"

    , testCase "no matching prefix → Nothing" $
        classifyControlType "xyz_unknown" @?= Nothing

    , testCase "case-insensitive match" $
        classifyControlType "DW_Main" @?= Just "datawindow"
    ]

  , testGroup "extractGlobalVars"
    [ testCase "global variable declaration extracted" $ do
        let sf = SrFile
              { srHeaders = [], srForward = Nothing, srPrototypes = Nothing
              , srVariables = Just (VariablesBlock GlobalVars
                  [VarDecl [] "long" "g_counter"])
              , srGlobalInstances = [], srTypeBlocks = []
              , srOnBlocks = [], srEvents = [], srFunctions = [], srSubroutines = []
              }
            gvs = extractGlobalVars "w.srf" "w_test" sf
        case gvs of
          [gv] -> do
            gvName gv @?= "g_counter"
            gvType gv @?= "long"
          other -> assertFailure ("expected 1 global var, got " <> show (length other))

    , testCase "empty file yields no global vars" $
        let sf = SrFile
              { srHeaders = [], srForward = Nothing, srPrototypes = Nothing
              , srVariables = Nothing, srGlobalInstances = []
              , srTypeBlocks = [], srOnBlocks = [], srEvents = []
              , srFunctions = [], srSubroutines = []
              }
        in extractGlobalVars "w.srf" "w_test" sf @?= []

    , testCase "forward-declared global instance is extracted" $
        let sf = emptySrFile
              { srForward = Just ForwardBlock
                  { fwdTypes = []
                  , fwdInstances = [GlobalInstance "transaction" "sqlca"]
                  }
              }
            gvs = extractGlobalVars "app.sra" "app" sf
        in case gvs of
          [gv] -> do
            gvName gv @?= "sqlca"
            gvType gv @?= "transaction"
          other -> assertFailure ("expected 1 global var, got " <> show (length other))
    ]

  , testGroup "extractDwControlBindings"
    [ testCase "dataobject on a within-block binds control -> dw name (w_dw_copy shape)" $
        let dataObjectVar = Located 1 BsLocalVar
              { varMods = [], varType = PtPrimitive "string"
              , varName = "DataObject", varInit = Just (ExStr "d_items") }
            tb = TypeBlock
              { tbDecl = TypeDecl { tdName = "dw_dest", tdAncestor = "datawindow", tdWithin = Just "w_dw_copy" }
              , tbBody = [dataObjectVar]
              }
            sf = emptySrFile { srTypeBlocks = [tb] }
        in extractDwControlBindings "w_dw_copy.srw" sf
             @?= [DwControlBinding "w_dw_copy.srw" "w_dw_copy" "dw_dest" "d_items"]

    , testCase "DataObject case-insensitive property name matched" $
        let dataObjectVar = Located 1 BsLocalVar
              { varMods = [], varType = PtPrimitive "string"
              , varName = "dataobject", varInit = Just (ExStr "dw_misth_final_details_list") }
            tb = TypeBlock
              { tbDecl = TypeDecl { tdName = "dw", tdAncestor = "w_list`dw", tdWithin = Just "w_misth_final_details_list" }
              , tbBody = [dataObjectVar]
              }
            sf = emptySrFile { srTypeBlocks = [tb] }
        in extractDwControlBindings "w.srw" sf
             @?= [DwControlBinding "w.srw" "w_misth_final_details_list" "dw" "dw_misth_final_details_list"]

    , testCase "no dataobject in block yields no binding" $
        let widthVar = Located 1 BsLocalVar
              { varMods = [], varType = PtPrimitive "integer"
              , varName = "width", varInit = Just (ExInt "3081") }
            tb = TypeBlock
              { tbDecl = TypeDecl { tdName = "dw", tdAncestor = "datawindow", tdWithin = Just "w_test" }
              , tbBody = [widthVar]
              }
            sf = emptySrFile { srTypeBlocks = [tb] }
        in extractDwControlBindings "w.srw" sf @?= []

    , testCase "outer type block (no within) binds as control name this" $
        let dataObjectVar = Located 1 BsLocalVar
              { varMods = [], varType = PtPrimitive "string"
              , varName = "dataobject", varInit = Just (ExStr "d_self") }
            tb = TypeBlock
              { tbDecl = TypeDecl { tdName = "w_selfdw", tdAncestor = "window", tdWithin = Nothing }
              , tbBody = [dataObjectVar]
              }
            sf = emptySrFile { srTypeBlocks = [tb] }
        in extractDwControlBindings "w.srw" sf
             @?= [DwControlBinding "w.srw" "w_selfdw" "this" "d_self"]
    ]

  , testGroup "resolveTypes/controlType"
    [ testCase "unresolved var with dw_ prefix falls back to datawindow" $ do
        let lv = LocalVar "w.srf" "w_test" "of_open" "dw_main"
                   "n_vo" False 1 (PtUserDefined "n_vo")
            result = resolveTypes [lv] Set.empty Set.empty
        case result of
          [rt] -> do
            rtKind   rt @?= "primitive"
            rtTarget rt @?= Just "datawindow"
          other -> assertFailure ("expected 1 result, got " <> show (length other))
    ]
  ]

dwMin :: T.Text
dwMin = T.intercalate "\n"
  [ "HA$PBExportHeader$test.srd"
  , "$PBExportComments$"
  , "release 9;"
  , "datawindow(units=0 )"
  ]
