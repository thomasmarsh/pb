module TypeResolveTest (tests) where

import Prelude
import Test.Tasty         (TestTree, testGroup)
import Test.Tasty.HUnit   ((@?=), assertFailure, testCase)

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T

import PB.AST.BodyStmt
import PB.AST.DataWindow   (DwTable (..), DwColumn (..))
import PB.AST.Expr
import PB.AST.Ident        (mkIdent, mkIdentAt, identMapEmpty, identMapFromList, identMapLookup,
                             identSetEmpty, identSetFromList, identSetMember, identSetSingleton)
import PB.AST.Located      (Located (..))
import PB.AST.SourceFile
import PB.AST.Type         (PbType (..))
import PB.Grammar.Body     (parseBodyStmts)
import PB.Grammar.DataWindow (parseDataWindow)
import PB.Lexing.Splitter  (Statement (..))
import PB.Lexing.Token     (Token (..), TokenKind (..), SourceSpan (..))
import PB.Pipeline.Preprocess (mkLogicalLine)
import PB.Analysis.ControlHierarchy (ControlIndex, buildControlIndex)
import PB.Analysis.TypeEnv (WorkspaceEnv, buildWorkspaceEnv, withDwTables, withDwParamBindings)
import PB.Analysis.TypeResolve

-- ---------------------------------------------------------------------------
-- Helpers

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
mkTB nm anc = TypeBlock
  { tbDecl = mkTypeDecl nm anc Nothing
  , tbBody = []
  }

mkDwCol :: T.Text -> T.Text -> DwColumn
mkDwCol nm ty = DwColumn
  { dcName = nm, dcType = ty, dcDbName = Nothing, dcUpdate = False
  , dcKey = False, dcUpdateWhere = False, dcDddwName = Nothing, dcAttrs = Map.empty
  }

mkDwTable :: [DwColumn] -> DwTable
mkDwTable cols = DwTable
  { dtColumns = cols, dtRetrieve = Nothing, dtUpdate = Nothing
  , dtUpdateWhere = Nothing, dtArguments = []
  }

-- | Test-only fixture helper: parses a simple comma-separated "[mods] type
-- name" list into synthetic-span 'Param's. Fixture construction only -- the
-- real token-level parser ('PB.Grammar.File.parseParamsAndThrows', which
-- mints real spans) is tested directly in FileTest.hs.
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
  { fbSig = FnSig
      { fnsMods           = []
      , fnsReturnType     = "integer"
      , fnsReturnTypeSpan = SourceSpan 1 1 1 1
      , fnsName           = mkIdent nm
      , fnsParams         = mkParams params
      , fnsThrows         = Nothing
      }
  , fbBody = body
  }

mkEv :: T.Text -> T.Text -> [Located BodyStmt] -> EventBlock
mkEv nm params body = EventBlock
  { evSig   = EventSig { esName = mkIdent nm, esParams = mkParams params }
  , evOwner = Nothing
  , evBody  = body
  }

localVarStmt :: T.Text -> PbType -> Int -> Located BodyStmt
localVarStmt nm ty line = Located line BsLocalVar
  { varMods = []
  , varType = ty
  , varName = mkIdent nm
  , varInit = Nothing
  }

callStmt :: T.Text -> Int -> Located BodyStmt
callStmt callee_ line = Located line
  (BsCall (ExCall
    { callee   = Lvalue [LvSegment (mkIdent callee_) Nothing]
    , callArgs = []
    }))

-- | Empty workspace-wide env\/control index -- sufficient for every
-- 'extractCallSites' test that only checks call-site enumeration
-- (name\/type\/line), not receiver-type resolution.
emptyWsEnv :: WorkspaceEnv
emptyWsEnv = buildWorkspaceEnv []

emptyControlIdx :: ControlIndex
emptyControlIdx = buildControlIndex []

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "TypeResolve"
  [ testGroup "classifyPbType"
      [ testCase "PtPrimitive string → primitive" $ do
          let (k, t) = classifyPbType (PtPrimitive "string") identSetEmpty identSetEmpty
          k @?= "primitive"
          t @?= Nothing

      , testCase "PtAny → any" $ do
          let (k, t) = classifyPbType PtAny identSetEmpty identSetEmpty
          k @?= "any"
          t @?= Nothing

      , testCase "PtDecimalPrec → primitive" $ do
          let (k, t) = classifyPbType (PtDecimalPrec 10) identSetEmpty identSetEmpty
          k @?= "primitive"
          t @?= Nothing

      , testCase "PtUserDefined in object set → object" $ do
          let (k, t) = classifyPbType (PtUserDefined "w_main")
                         (identSetSingleton (mkIdent "w_main")) identSetEmpty
          k @?= "object"
          t @?= Just "w_main"

      , testCase "PtUserDefined in user type set → user_type" $ do
          let (k, t) = classifyPbType (PtUserDefined "n_cst_service")
                         identSetEmpty (identSetSingleton (mkIdent "n_cst_service"))
          k @?= "user_type"
          t @?= Just "n_cst_service"

      , testCase "PtUserDefined case-insensitive match recovers declared casing" $ do
          let (k, t) = classifyPbType (PtUserDefined "W_Main")
                         (identSetSingleton (mkIdent "w_main")) identSetEmpty
          k @?= "object"
          t @?= Just "w_main"

      , testCase "PtUserDefined datawindow → primitive" $ do
          let (k, t) = classifyPbType (PtUserDefined "datawindow") identSetEmpty identSetEmpty
          k @?= "primitive"
          t @?= Nothing

      , testCase "PtUserDefined Window mixed-case → primitive" $ do
          let (k, t) = classifyPbType (PtUserDefined "Window") identSetEmpty identSetEmpty
          k @?= "primitive"
          t @?= Nothing

      , testCase "PtUserDefined xyz_unknown → unresolved" $ do
          let (k, t) = classifyPbType (PtUserDefined "xyz_unknown") identSetEmpty identSetEmpty
          k @?= "unresolved"
          t @?= Nothing

      , testCase "PtPrimitive datawindow → object (built-in class, not value primitive)" $ do
          let (k, t) = classifyPbType (PtPrimitive "datawindow") identSetEmpty identSetEmpty
          k @?= "object"
          t @?= Just "datawindow"

      , testCase "PtPrimitive transaction → object (built-in class)" $ do
          let (k, t) = classifyPbType (PtPrimitive "transaction") identSetEmpty identSetEmpty
          k @?= "object"
          t @?= Just "transaction"
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

      , testCase "event params from EventSig (Plan 196 Phase 3: events previously never got their own params here)" $ do
          let sf = emptySrFile { srEvents = [ mkEv "ue_scroll" "integer ai_scroll" [] ] }
          case extractLocalVars "test.srw" "w_test" sf of
            [v] -> do
              lvIsParam v @?= True
              lvVarName v @?= "ai_scroll"
              lvRawType v @?= "integer"
            other -> assertFailure ("expected 1 var, got " ++ show (length other))

      , testCase "params before body vars" $ do
          let body = [ localVarStmt "ls_x" (PtPrimitive "string") 5 ]
              sf   = emptySrFile { srFunctions = [ mkFn "f_go" "long al_row" body ] }
          case extractLocalVars "test.srw" "w_test" sf of
            [a, b] -> do
              lvIsParam a @?= True
              lvIsParam b @?= False
            other -> assertFailure ("expected 2 vars, got " ++ show (length other))

      , testCase "comma-separated declaration (long ll_rows, i) expands into separate vars" $ do
          -- Confirms Body.classifyBodyStmt's comma-split fix (Plan 193 Phase 1)
          -- cascades for free: walkStmtLocalVars/extractLocalVars need no
          -- change since they already concatMap over [Located BodyStmt].
          let mkTok k t = Token k t (SourceSpan 30 30 30 30)
              stmt = Statement
                { stmtTokens     = [ mkTok TkDatatype "long", mkTok TkIdent "ll_rows"
                                   , mkTok TkComma ",", mkTok TkIdent "i" ]
                , stmtSource     = mkLogicalLine "" 30
                , stmtTerminated = False
                }
              sf = emptySrFile { srFunctions = [ mkFn "f_go" "" (parseBodyStmts [stmt]) ] }
          case extractLocalVars "test.srw" "w_test" sf of
            [a, b] -> do
              lvVarName a @?= "ll_rows"
              lvVarName b @?= "i"
            other -> assertFailure ("expected 2 vars, got " ++ show (length other))

      , testCase "BsLocalVar nested inside try-body and catch-body" $ do
          let stmt = Located 15 (BsTry (TryStmt
                [ localVarStmt "li_try" (PtPrimitive "integer") 16 ]
                [ CatchClause "Exception" "e"
                    [ localVarStmt "li_catch" (PtPrimitive "integer") 17 ] ]))
              sf = emptySrFile { srFunctions = [ mkFn "f_go" "" [stmt] ] }
          case extractLocalVars "test.srw" "w_test" sf of
            [a, b] -> do
              lvVarName a @?= "li_try"
              lvVarName b @?= "li_catch"
            other -> assertFailure ("expected 2 vars, got " ++ show (length other))
      ]

  , testGroup "extractCallSites"
      [ testCase "empty SrFile → []" $
          extractCallSites emptyWsEnv emptyControlIdx "test.srw" "w_test" emptySrFile @?= []

      , testCase "ExCall from BsCall" $ do
          let body  = [ callStmt "f_helper" 5 ]
              sf    = emptySrFile { srFunctions = [ mkFn "f_go" "" body ] }
          case extractCallSites emptyWsEnv emptyControlIdx "test.srw" "w_test" sf of
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
          case extractCallSites emptyWsEnv emptyControlIdx "test.srw" "w_test" sf of
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
          case extractCallSites emptyWsEnv emptyControlIdx "test.srw" "w_test" sf of
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
          case extractCallSites emptyWsEnv emptyControlIdx "test.srw" "w_test" sf of
            [s] -> csToName s @?= "of_checkdelete"
            other -> assertFailure ("expected 1 site, got " ++ show (length other))

      , testCase "calls extracted from try-body and catch-body" $ do
          let body = [ Located 10 (BsTry (TryStmt
                [ callStmt "f_try" 11 ]
                [ CatchClause "Exception" "e" [ callStmt "f_catch" 12 ] ])) ]
              sf = emptySrFile { srFunctions = [ mkFn "f_go" "" body ] }
          case extractCallSites emptyWsEnv emptyControlIdx "test.srw" "w_test" sf of
            [s1, s2] -> do
              csToName s1 @?= "f_try"
              csToName s2 @?= "f_catch"
            other -> assertFailure ("expected 2 sites, got " ++ show (length other))

      -- Plan 195 Phase E.5b: two same-named calls sharing one physical
      -- line (the same 'csLine', both statement lines equal) must still
      -- be distinguishable by 'csToNameSpan''s column -- the actual
      -- regression case Phase F exists to fix, since 'csLine' alone
      -- cannot tell the two call sites apart.
      , testCase "two calls sharing one physical line are distinguished by csToNameSpan column" $ do
          let sp1  = SourceSpan 20 1 20 8
              sp2  = SourceSpan 20 11 20 18
              body = [ Located 20 (BsCall (ExCall
                         { callee   = Lvalue [LvSegment (mkIdentAt sp1 "f_dupe") Nothing]
                         , callArgs = []
                         }))
                     , Located 20 (BsCall (ExCall
                         { callee   = Lvalue [LvSegment (mkIdentAt sp2 "f_dupe") Nothing]
                         , callArgs = []
                         })) ]
              sf = emptySrFile { srFunctions = [ mkFn "f_go" "" body ] }
          case extractCallSites emptyWsEnv emptyControlIdx "test.srw" "w_test" sf of
            [s1, s2] -> do
              csLine s1 @?= csLine s2
              csToNameSpan s1 @?= Just sp1
              csToNameSpan s2 @?= Just sp2
            other -> assertFailure ("expected 2 sites, got " ++ show (length other))

      , testCase "nested ExMethodCall receiver: a.b().c() yields call sites for both b and c" $ do
          -- Plan 195's confirmed 'ExMethodCall.receiver under-recursion' bug:
          -- the receiver of an ExMethodCall is itself a call and must be
          -- walked, not just the outer method. foldExprs is pre-order (node
          -- before children), so the outer call (c) is reported before the
          -- inner receiver call (b).
          let body = [ Located 5
                (BsCall (ExMethodCall
                  { receiver = ExMethodCall
                      { receiver   = ExLvalue (Lvalue [LvSegment "a" Nothing])
                      , method     = "b"
                      , methodArgs = []
                      }
                  , method     = "c"
                  , methodArgs = []
                  })) ]
              sf = emptySrFile { srFunctions = [ mkFn "f_go" "" body ] }
          case extractCallSites emptyWsEnv emptyControlIdx "test.srw" "w_test" sf of
            [s1, s2] -> do
              csToName s1 @?= "c"
              csToName s2 @?= "b"
            other -> assertFailure ("expected 2 sites, got " ++ show (length other))

      , testCase "ExMethodCall receiver resolves this/super/a bare control name (Plan 195 Phase D)" $ do
          -- 'this' -> the enclosing object itself; 'super' -> one hop up
          -- 'weHierarchy' (both via 'lookupScopedVarOrSelf'); 'dw_1' -> a
          -- nested TypeBlock control, only reachable via 'ControlIndex'
          -- ('resolveLvalueType''s single-segment fallback) since a control
          -- is never a 'BsLocalVar', so it can never appear in
          -- 'steLocal'\/'steInstance'\/'steGlobal'.
          let recvCall recv line = Located line
                (BsCall (ExMethodCall
                  { receiver   = ExLvalue (Lvalue [LvSegment recv Nothing])
                  , method     = "retrieve"
                  , methodArgs = []
                  }))
              body = [ recvCall "this" 5, recvCall "super" 6, recvCall "dw_1" 7 ]
              sf = emptySrFile
                { srTypeBlocks =
                    [ mkTB "w_test" "window"
                    , TypeBlock (mkTypeDecl "dw_1" "datawindow" (Just "w_test")) []
                    ]
                , srFunctions = [ mkFn "f_go" "" body ]
                }
              wsEnv = buildWorkspaceEnv [sf]
              idx   = buildControlIndex [sf]
          case extractCallSites wsEnv idx "test.srw" "w_test" sf of
            [s1, s2, s3] -> do
              csReceiverObject s1 @?= Just "w_test"     -- this
              csReceiverObject s2 @?= Just "window"     -- super
              csReceiverObject s3 @?= Just "datawindow" -- dw_1 (control, via ControlIndex)
            other -> assertFailure ("expected 3 sites, got " ++ show (length other))

      , testCase "ExMethodCall receiver resolves a multi-segment plain instance-var chain (Plan 196 Phase 4 item 2)" $ do
          -- Real corpus shape: iw_parent.ilst_history.ishead(), where
          -- iw_parent is a plain instance var (type w_child) and
          -- ilst_history is in turn a plain instance var declared on
          -- w_child -- previously unresolvable since
          -- 'CallClassify.resolveLvalueType''s multi-segment branch only
          -- ever walked 'ControlIndex', never 'weInstanceVars'.
          let body = [ Located 5 (BsCall (ExMethodCall
                { receiver   = ExLvalue (Lvalue [LvSegment "iw_parent" Nothing, LvSegment "ilst_history" Nothing])
                , method     = "ishead"
                , methodArgs = []
                })) ]
              sf = emptySrFile
                { srTypeBlocks = [ TypeBlock (mkTypeDecl "w_test" "window" Nothing)
                    [ Located 1 (BsLocalVar [] (PtUserDefined "w_child") "iw_parent" Nothing) ] ]
                , srFunctions = [ mkFn "f_go" "" body ]
                }
              sfChild = emptySrFile
                { srTypeBlocks = [ TypeBlock (mkTypeDecl "w_child" "window" Nothing)
                    [ Located 1 (BsLocalVar [] (PtUserDefined "uc_lnklist") "ilst_history" Nothing) ] ] }
              wsEnv = buildWorkspaceEnv [sf, sfChild]
              idx   = buildControlIndex [sf, sfChild]
          case extractCallSites wsEnv idx "test.srw" "w_test" sf of
            [s] -> csReceiverObject s @?= Just "uc_lnklist"
            other -> assertFailure ("expected 1 site, got " ++ show (length other))

      , testCase "ExMethodCall receiver resolves a 3+-hop pure nested-control chain (regression)" $ do
          -- Real corpus shape: tab1.page1.uo_epidom.uf_filter(), all three
          -- pure nested visual-tree controls with no intervening instance
          -- var -- resolveMemberChainType/resolveChain must be walked with
          -- the FULL segment list from a stable root (w_test); re-deriving
          -- one hop at a time from just the previous hop's resolved TYPE
          -- (the first version of this fix) silently broke this exact shape,
          -- caught by real-corpus --db re-verification before this session's
          -- Stage 4 (final.pbl/w_misth_final_details_form_edit.srw:74).
          let body = [ Located 5 (BsCall (ExMethodCall
                { receiver   = ExLvalue (Lvalue
                    [LvSegment "tab1" Nothing, LvSegment "page1" Nothing, LvSegment "uo_epidom" Nothing])
                , method     = "uf_filter"
                , methodArgs = []
                })) ]
              sf = emptySrFile
                { srTypeBlocks =
                    [ mkTB "w_test" "window"
                    , TypeBlock (mkTypeDecl "tab1" "tab" (Just "w_test")) []
                    , TypeBlock (mkTypeDecl "page1" "tabpage" (Just "tab1")) []
                    , TypeBlock (mkTypeDecl "uo_epidom" "u_epidom" (Just "page1")) []
                    ]
                , srFunctions = [ mkFn "f_go" "" body ]
                }
              wsEnv = buildWorkspaceEnv [sf]
              idx   = buildControlIndex [sf]
          case extractCallSites wsEnv idx "test.srw" "w_test" sf of
            [s] -> csReceiverObject s @?= Just "u_epidom"
            other -> assertFailure ("expected 1 site, got " ++ show (length other))
      ]

  , testGroup "extractVarRefs"
      [ testCase "empty SrFile -> []" $
          extractVarRefs emptyWsEnv emptyControlIdx "test.srw" "w_test" emptySrFile @?= []

      , testCase "local var: write then read" $ do
          let body = [ localVarStmt "ll_x" (PtPrimitive "long") 5
                     , Located 6 (BsAssign (Lvalue [LvSegment "ll_x" Nothing]) (ExInt "1"))
                     , Located 7 (BsReturn (Just (ExLvalue (Lvalue [LvSegment "ll_x" Nothing]))))
                     ]
              sf = emptySrFile { srFunctions = [ mkFn "f_go" "" body ] }
          case extractVarRefs emptyWsEnv emptyControlIdx "test.srw" "w_test" sf of
            [w, r] -> do
              (rvrName w, rvrAccess w, rvrKind w, rvrLine w) @?= ("ll_x", "write", "local", Just 6)
              (rvrName r, rvrAccess r, rvrKind r, rvrLine r) @?= ("ll_x", "read",  "local", Just 7)
            other -> assertFailure ("expected 2 refs, got " ++ show (length other))

      , testCase "param: read in return" $ do
          let body = [ Located 5 (BsReturn (Just (ExLvalue (Lvalue [LvSegment "al_row" Nothing])))) ]
              sf = emptySrFile { srFunctions = [ mkFn "f_go" "long al_row" body ] }
          case extractVarRefs emptyWsEnv emptyControlIdx "test.srw" "w_test" sf of
            [r] -> (rvrKind r, rvrAccess r) @?= ("param", "read")
            other -> assertFailure ("expected 1 ref, got " ++ show (length other))

      , testCase "instance var: own object's TypeBlock BsLocalVar" $ do
          let sf = emptySrFile
                { srTypeBlocks = [ TypeBlock (mkTypeDecl "w_test" "window" Nothing)
                    [ Located 1 (BsLocalVar [] (PtPrimitive "long") "ai_count" Nothing) ] ]
                , srFunctions = [ mkFn "f_go" ""
                    [ Located 5 (BsReturn (Just (ExLvalue (Lvalue [LvSegment "ai_count" Nothing])))) ] ]
                }
              wsEnv = buildWorkspaceEnv [sf]
          case extractVarRefs wsEnv emptyControlIdx "test.srw" "w_test" sf of
            [r] -> (rvrKind r, rvrTargetObject r) @?= ("instance", Just "w_test")
            other -> assertFailure ("expected 1 ref, got " ++ show (length other))

      , testCase "write access to an instance var via BsAssign" $ do
          let sf = emptySrFile
                { srTypeBlocks = [ TypeBlock (mkTypeDecl "w_test" "window" Nothing)
                    [ Located 1 (BsLocalVar [] (PtPrimitive "long") "ai_count" Nothing) ] ]
                , srFunctions = [ mkFn "f_go" ""
                    [ Located 5 (BsAssign (Lvalue [LvSegment "ai_count" Nothing]) (ExInt "1")) ] ]
                }
              wsEnv = buildWorkspaceEnv [sf]
          case extractVarRefs wsEnv emptyControlIdx "test.srw" "w_test" sf of
            [r] -> (rvrAccess r, rvrKind r) @?= ("write", "instance")
            other -> assertFailure ("expected 1 ref, got " ++ show (length other))

      , testCase "instance var declared only on an ancestor object resolves through extraction" $ do
          let sfParent = emptySrFile
                { srTypeBlocks = [ TypeBlock (mkTypeDecl "w_parent" "window" Nothing)
                    [ Located 1 (BsLocalVar [] (PtPrimitive "long") "ai_count" Nothing) ] ] }
              sfChild = emptySrFile
                { srTypeBlocks = [ mkTB "w_child" "w_parent" ]
                , srFunctions  = [ mkFn "f_go" ""
                    [ Located 5 (BsReturn (Just (ExLvalue (Lvalue [LvSegment "ai_count" Nothing])))) ] ]
                }
              wsEnv = buildWorkspaceEnv [sfParent, sfChild]
          case extractVarRefs wsEnv emptyControlIdx "test.srw" "w_child" sfChild of
            [r] -> (rvrKind r, rvrTargetObject r) @?= ("instance", Just "w_parent")
            other -> assertFailure ("expected 1 ref, got " ++ show (length other))

      , testCase "own instance var shadows a same-named ancestor var (duplicate-key adversarial case)" $ do
          let sfParent = emptySrFile
                { srTypeBlocks = [ TypeBlock (mkTypeDecl "w_parent" "window" Nothing)
                    [ Located 1 (BsLocalVar [] (PtPrimitive "long") "ai_count" Nothing) ] ] }
              sfChild = emptySrFile
                { srTypeBlocks = [ TypeBlock (mkTypeDecl "w_child" "w_parent" Nothing)
                    [ Located 1 (BsLocalVar [] (PtPrimitive "string") "ai_count" Nothing) ] ]
                , srFunctions  = [ mkFn "f_go" ""
                    [ Located 5 (BsReturn (Just (ExLvalue (Lvalue [LvSegment "ai_count" Nothing])))) ] ]
                }
              wsEnv = buildWorkspaceEnv [sfParent, sfChild]
          case extractVarRefs wsEnv emptyControlIdx "test.srw" "w_child" sfChild of
            [r] -> rvrTargetObject r @?= Just "w_child"
            other -> assertFailure ("expected 1 ref, got " ++ show (length other))

      , testCase "global var" $ do
          let sf = emptySrFile
                { srVariables = [ VariablesBlock GlobalVars [ VarDecl [] "boolean" (SourceSpan 1 1 1 1) "ig_flag" ] ]
                , srFunctions = [ mkFn "f_go" ""
                    [ Located 5 (BsReturn (Just (ExLvalue (Lvalue [LvSegment "ig_flag" Nothing])))) ] ]
                }
              wsEnv = buildWorkspaceEnv [sf]
          case extractVarRefs wsEnv emptyControlIdx "test.srw" "w_test" sf of
            [r] -> rvrKind r @?= "global"
            other -> assertFailure ("expected 1 ref, got " ++ show (length other))

      , testCase "this/super/control root segments" $ do
          let body = [ Located 5 (BsReturn (Just (ExLvalue (Lvalue [LvSegment "this" Nothing]))))
                     , Located 6 (BsReturn (Just (ExLvalue (Lvalue [LvSegment "super" Nothing]))))
                     , Located 7 (BsReturn (Just (ExLvalue (Lvalue [LvSegment "dw_1" Nothing]))))
                     ]
              sf = emptySrFile
                { srTypeBlocks =
                    [ mkTB "w_test" "window"
                    , TypeBlock (mkTypeDecl "dw_1" "datawindow" (Just "w_test")) []
                    ]
                , srFunctions = [ mkFn "f_go" "" body ]
                }
              wsEnv = buildWorkspaceEnv [sf]
              idx   = buildControlIndex [sf]
          case extractVarRefs wsEnv idx "test.srw" "w_test" sf of
            [r1, r2, r3] -> do
              (rvrKind r1, rvrTargetObject r1) @?= ("class",   Just "w_test")
              (rvrKind r2, rvrTargetObject r2) @?= ("class",   Just "window")
              (rvrKind r3, rvrTargetObject r3) @?= ("control", Just "datawindow")
            other -> assertFailure ("expected 3 refs, got " ++ show (length other))

      , testCase "dotted: every segment of uo_1.ai_count resolves independently, not just the tail" $ do
          let sf = emptySrFile
                { srTypeBlocks =
                    [ mkTB "w_test" "window"
                    , TypeBlock (mkTypeDecl "uo_1" "u_helper" (Just "w_test")) []
                    ]
                , srFunctions = [ mkFn "f_go" ""
                    [ Located 5 (BsReturn (Just (ExLvalue (Lvalue
                        [LvSegment "uo_1" Nothing, LvSegment "ai_count" Nothing])))) ] ]
                }
              sfHelper = emptySrFile
                { srTypeBlocks = [ TypeBlock (mkTypeDecl "u_helper" "userobject" Nothing)
                    [ Located 1 (BsLocalVar [] (PtPrimitive "long") "ai_count" Nothing) ] ] }
              wsEnv = buildWorkspaceEnv [sf, sfHelper]
              idx   = buildControlIndex [sf, sfHelper]
          case extractVarRefs wsEnv idx "test.srw" "w_test" sf of
            [receiver, tail_] -> do
              (rvrName receiver, rvrKind receiver, rvrTargetObject receiver, rvrAccess receiver, rvrDeclaredType receiver)
                @?= ("uo_1", "control", Just "u_helper", "read", Just "u_helper")
              (rvrName tail_, rvrKind tail_, rvrTargetObject tail_, rvrAccess tail_, rvrDeclaredType tail_)
                @?= ("ai_count", "instance", Just "u_helper", "read", Just "long")
            other -> assertFailure ("expected 2 refs (one per segment), got " ++ show (length other))

      , testCase "dotted: builtin property when the receiver resolves to a known builtin class" $ do
          let sf = emptySrFile
                { srTypeBlocks =
                    [ mkTB "w_test" "window"
                    , TypeBlock (mkTypeDecl "dw_1" "datawindow" (Just "w_test")) []
                    ]
                , srFunctions = [ mkFn "f_go" ""
                    [ Located 5 (BsReturn (Just (ExLvalue (Lvalue
                        [LvSegment "dw_1" Nothing, LvSegment "some_prop" Nothing])))) ] ]
                }
              wsEnv = buildWorkspaceEnv [sf]
              idx   = buildControlIndex [sf]
          case extractVarRefs wsEnv idx "test.srw" "w_test" sf of
            [receiver, tail_] -> do
              (rvrKind receiver, rvrDeclaredType receiver) @?= ("control", Just "datawindow")
              (rvrKind tail_, rvrDeclaredType tail_) @?= ("builtin_property", Nothing)
            other -> assertFailure ("expected 2 refs (one per segment), got " ++ show (length other))

      , testCase "dotted: inherited builtin property resolves via ancestor chain, not just a direct name match" $ do
          -- w_printer's own name is not "window", but it descends from it
          -- (Plan 196 Phase 4, item 3 -- real corpus: afxlib.pbl/w_printer.srw:97,
          -- this.Control[]={this.cbx_1,&...}).
          let sf = emptySrFile
                { srTypeBlocks = [ mkTB "w_printer" "window" ]
                , srFunctions = [ mkFn "f_go" ""
                    [ Located 5 (BsReturn (Just (ExLvalue (Lvalue
                        [LvSegment "this" Nothing, LvSegment "Control" Nothing])))) ] ]
                }
              wsEnv = buildWorkspaceEnv [sf]
          case extractVarRefs wsEnv emptyControlIdx "test.srw" "w_printer" sf of
            [receiver, tail_] -> do
              (rvrKind receiver, rvrTargetObject receiver) @?= ("class", Just "w_printer")
              (rvrKind tail_, rvrDeclaredType tail_) @?= ("builtin_property", Nothing)
            other -> assertFailure ("expected 2 refs, got " ++ show (length other))

      , testCase "bare single-segment builtin property (implicit self-access, no explicit this.)" $ do
          -- A menu item's bare 'ParentWindow' with no qualifying receiver at
          -- all (real corpus: m_misth_final_details_list.srm:462, "parentwindow.triggerevent(...)").
          let sf = emptySrFile
                { srTypeBlocks = [ mkTB "m_test" "menu" ]
                , srFunctions = [ mkFn "f_go" ""
                    [ Located 5 (BsReturn (Just (ExLvalue (Lvalue [LvSegment "parentwindow" Nothing])))) ] ]
                }
              wsEnv = buildWorkspaceEnv [sf]
          case extractVarRefs wsEnv emptyControlIdx "test.srw" "m_test" sf of
            [r] -> rvrKind r @?= "builtin_property"
            other -> assertFailure ("expected 1 ref, got " ++ show (length other))

      , testCase "nested control reached via a plain instance-var hop resolves at hop 2+, not just hop 1" $ do
          -- iw_parent (instance var of type w_child) . dw_main (a control
          -- declared on w_child, not a BsLocalVar) -- real corpus:
          -- wiz_misth_final_details.srw:45, uo_step1.dw_misth_final.update().
          let sf = emptySrFile
                { srTypeBlocks = [ TypeBlock (mkTypeDecl "w_test" "window" Nothing)
                    [ Located 1 (BsLocalVar [] (PtUserDefined "w_child") "iw_parent" Nothing) ] ]
                , srFunctions = [ mkFn "f_go" ""
                    [ Located 5 (BsReturn (Just (ExLvalue (Lvalue
                        [LvSegment "iw_parent" Nothing, LvSegment "dw_main" Nothing])))) ] ]
                }
              sfChild = emptySrFile
                { srTypeBlocks =
                    [ mkTB "w_child" "window"
                    , TypeBlock (mkTypeDecl "dw_main" "datawindow" (Just "w_child")) []
                    ]
                }
              wsEnv = buildWorkspaceEnv [sf, sfChild]
              idx   = buildControlIndex [sf, sfChild]
          case extractVarRefs wsEnv idx "test.srw" "w_test" sf of
            [receiver, tail_] -> do
              (rvrKind receiver, rvrDeclaredType receiver) @?= ("instance", Just "w_child")
              (rvrKind tail_, rvrDeclaredType tail_) @?= ("control", Just "datawindow")
            other -> assertFailure ("expected 2 refs, got " ++ show (length other))

      , testCase "var ref: a 3+-hop pure nested-control chain resolves every hop from the same stable anchor (regression)" $ do
          -- Same real-corpus shape and same regression as the ExMethodCall
          -- receiver version above (tab1.page1.uo_epidom), but for a plain
          -- var read rather than a call receiver.
          let sf = emptySrFile
                { srTypeBlocks =
                    [ mkTB "w_test" "window"
                    , TypeBlock (mkTypeDecl "tab1" "tab" (Just "w_test")) []
                    , TypeBlock (mkTypeDecl "page1" "tabpage" (Just "tab1")) []
                    , TypeBlock (mkTypeDecl "uo_epidom" "u_epidom" (Just "page1")) []
                    ]
                , srFunctions = [ mkFn "f_go" ""
                    [ Located 5 (BsReturn (Just (ExLvalue (Lvalue
                        [LvSegment "tab1" Nothing, LvSegment "page1" Nothing, LvSegment "uo_epidom" Nothing])))) ] ]
                }
              wsEnv = buildWorkspaceEnv [sf]
              idx   = buildControlIndex [sf]
          case extractVarRefs wsEnv idx "test.srw" "w_test" sf of
            [hop1, hop2, hop3] -> do
              (rvrKind hop1, rvrDeclaredType hop1) @?= ("control", Just "tab")
              (rvrKind hop2, rvrDeclaredType hop2) @?= ("control", Just "tabpage")
              (rvrKind hop3, rvrDeclaredType hop3) @?= ("control", Just "u_epidom")
            other -> assertFailure ("expected 3 refs, got " ++ show (length other))

      , testCase "dotted: adw.object.<column> on a bare datawindow param resolves 'object', column is dw_column with no known type (unbound)" $ do
          -- Real corpus shape: uo_misth_final_ypal_epidom_details_grid.sru:28,
          -- adw.object.kodfinal[row] where adw is a bare 'ref datawindow adw'
          -- param with no static binding -- Plan 196 Phase 4 item 1's
          -- "genuinely unknown" case: kind stays dw_column (we know this is
          -- a dynamic column read), declared_type stays Nothing (we don't
          -- know which .srd, so we can't know the column's real type).
          let sf = emptySrFile
                { srFunctions = [ mkFn "f_go" "datawindow adw"
                    [ Located 5 (BsReturn (Just (ExLvalue (Lvalue
                        [LvSegment "adw" Nothing, LvSegment "object" Nothing, LvSegment "kodfinal" Nothing])))) ] ] }
              wsEnv = buildWorkspaceEnv [sf]
          case extractVarRefs wsEnv emptyControlIdx "test.srw" "w_test" sf of
            [_param, objSeg, colSeg] -> do
              (rvrKind objSeg, rvrDeclaredType objSeg) @?= ("builtin_property", Nothing)
              (rvrKind colSeg, rvrDeclaredType colSeg, rvrConfidence colSeg) @?= ("dw_column", Nothing, "low")
            other -> assertFailure ("expected 3 refs, got " ++ show (length other))

      , testCase "dotted: dw_1.object.<column> on a statically-bound DW control resolves the column's real declared type" $ do
          -- dw_1's own dataobject="d_test" is known (ControlHierarchy), and
          -- d_test's own .srd column list (weDwTables) declares kodfinal as
          -- type "string" -- the column segment should get that real type,
          -- not a generic/unknown placeholder.
          let sf = emptySrFile
                { srTypeBlocks =
                    [ mkTB "w_test" "window"
                    , TypeBlock (mkTypeDecl "dw_1" "datawindow" (Just "w_test"))
                        [ Located 1 (BsLocalVar [] (PtPrimitive "string") "dataobject" (Just (ExStr "d_test"))) ]
                    ]
                , srFunctions = [ mkFn "f_go" ""
                    [ Located 5 (BsReturn (Just (ExLvalue (Lvalue
                        [LvSegment "dw_1" Nothing, LvSegment "object" Nothing, LvSegment "kodfinal" Nothing])))) ] ]
                }
              wsEnv = withDwTables (Map.fromList [("d_test", mkDwTable [mkDwCol "kodfinal" "string"])])
                        (buildWorkspaceEnv [sf])
              idx = buildControlIndex [sf]
          case extractVarRefs wsEnv idx "test.srw" "w_test" sf of
            [_ctrl, objSeg, colSeg] -> do
              (rvrKind objSeg, rvrDeclaredType objSeg) @?= ("builtin_property", Just "d_test")
              (rvrKind colSeg, rvrDeclaredType colSeg, rvrConfidence colSeg) @?= ("dw_column", Just "string", "high")
            other -> assertFailure ("expected 3 refs, got " ++ show (length other))

      , testCase "dotted: adw.object.<column> resolves the column's real type once Plan 196 Phase 4 item 1's param-binding trace supplies adw's inferred DW" $ do
          -- Combines Part D (weDwTables) and Part E (weDwParamBindings):
          -- 'adw' is still a bare, unbound-at-declaration 'datawindow' param,
          -- but the workspace-wide DwParamBinding trace (built separately,
          -- from every caller's own literal argument -- see
          -- DwParamBindingTest.hs) has already determined it's always
          -- 'd_test' -- exactly the corpus shape this phase set out to fix.
          let sf = emptySrFile
                { srFunctions = [ mkFn "f_go" "datawindow adw"
                    [ Located 5 (BsReturn (Just (ExLvalue (Lvalue
                        [LvSegment "adw" Nothing, LvSegment "object" Nothing, LvSegment "kodfinal" Nothing])))) ] ] }
              wsEnv = withDwParamBindings (Map.singleton ("w_test", "f_go", 0) "d_test")
                        (withDwTables (Map.fromList [("d_test", mkDwTable [mkDwCol "kodfinal" "string"])])
                          (buildWorkspaceEnv [sf]))
          case extractVarRefs wsEnv emptyControlIdx "test.srw" "w_test" sf of
            [_param, objSeg, colSeg] -> do
              (rvrKind objSeg, rvrDeclaredType objSeg) @?= ("builtin_property", Just "d_test")
              (rvrKind colSeg, rvrDeclaredType colSeg, rvrConfidence colSeg) @?= ("dw_column", Just "string", "high")
            other -> assertFailure ("expected 3 refs, got " ++ show (length other))

      , testCase "dotted: unresolvable receiver -> every segment unresolved, no guessing" $ do
          let sf = emptySrFile { srFunctions = [ mkFn "f_go" ""
                    [ Located 5 (BsReturn (Just (ExLvalue (Lvalue
                        [LvSegment "unknown_ctrl" Nothing, LvSegment "prop" Nothing])))) ] ] }
          case extractVarRefs emptyWsEnv emptyControlIdx "test.srw" "w_test" sf of
            [receiver, tail_] -> do
              (rvrKind receiver, rvrConfidence receiver, rvrTargetObject receiver) @?= ("unresolved", "unresolved", Nothing)
              (rvrKind tail_, rvrConfidence tail_, rvrTargetObject tail_) @?= ("unresolved", "unresolved", Nothing)
            other -> assertFailure ("expected 2 refs (one per segment), got " ++ show (length other))

      , testCase "three-hop chain resolves every segment, not just the tail" $ do
          let sf = emptySrFile
                { srTypeBlocks =
                    [ mkTB "w_test" "window"
                    , TypeBlock (mkTypeDecl "uo_1" "u_outer" (Just "w_test")) []
                    ]
                , srFunctions = [ mkFn "f_go" ""
                    [ Located 5 (BsReturn (Just (ExLvalue (Lvalue
                        [ LvSegment "uo_1" Nothing, LvSegment "io_inner" Nothing, LvSegment "ai_count" Nothing ])))) ] ]
                }
              sfOuter = emptySrFile
                { srTypeBlocks = [ TypeBlock (mkTypeDecl "u_outer" "userobject" Nothing)
                    [ Located 1 (BsLocalVar [] (PtUserDefined "u_inner") "io_inner" Nothing) ] ] }
              sfInner = emptySrFile
                { srTypeBlocks = [ TypeBlock (mkTypeDecl "u_inner" "userobject" Nothing)
                    [ Located 1 (BsLocalVar [] (PtPrimitive "long") "ai_count" Nothing) ] ] }
              wsEnv = buildWorkspaceEnv [sf, sfOuter, sfInner]
              idx   = buildControlIndex [sf, sfOuter, sfInner]
          case extractVarRefs wsEnv idx "test.srw" "w_test" sf of
            [hop1, hop2, hop3] -> do
              (rvrName hop1, rvrKind hop1, rvrDeclaredType hop1) @?= ("uo_1", "control", Just "u_outer")
              (rvrName hop2, rvrKind hop2, rvrTargetObject hop2, rvrDeclaredType hop2)
                @?= ("io_inner", "instance", Just "u_outer", Just "u_inner")
              (rvrName hop3, rvrKind hop3, rvrTargetObject hop3, rvrDeclaredType hop3)
                @?= ("ai_count", "instance", Just "u_inner", Just "long")
            other -> assertFailure ("expected 3 refs (one per segment), got " ++ show (length other))

      , testCase "write to a chain: trailing segment carries write access, receiver segments stay read" $ do
          let sf = emptySrFile
                { srTypeBlocks =
                    [ mkTB "w_test" "window"
                    , TypeBlock (mkTypeDecl "uo_1" "u_helper" (Just "w_test")) []
                    ]
                , srFunctions = [ mkFn "f_go" ""
                    [ Located 5 (BsAssign (Lvalue [LvSegment "uo_1" Nothing, LvSegment "ai_count" Nothing]) (ExInt "1")) ] ]
                }
              sfHelper = emptySrFile
                { srTypeBlocks = [ TypeBlock (mkTypeDecl "u_helper" "userobject" Nothing)
                    [ Located 1 (BsLocalVar [] (PtPrimitive "long") "ai_count" Nothing) ] ] }
              wsEnv = buildWorkspaceEnv [sf, sfHelper]
              idx   = buildControlIndex [sf, sfHelper]
          case extractVarRefs wsEnv idx "test.srw" "w_test" sf of
            [receiver, tail_] -> do
              rvrAccess receiver @?= "read"
              rvrAccess tail_    @?= "write"
            other -> assertFailure ("expected 2 refs (one per segment), got " ++ show (length other))

      , testCase "mid-chain hop's own instance var is shadowed by the nearer ancestor, not the base class (adversarial)" $ do
          let sf = emptySrFile
                { srTypeBlocks =
                    [ mkTB "w_test" "window"
                    , TypeBlock (mkTypeDecl "uo_1" "u_mid" (Just "w_test")) []
                    ]
                , srFunctions = [ mkFn "f_go" ""
                    [ Located 5 (BsReturn (Just (ExLvalue (Lvalue
                        [ LvSegment "uo_1" Nothing, LvSegment "ai_count" Nothing ])))) ] ]
                }
              sfBase = emptySrFile
                { srTypeBlocks = [ TypeBlock (mkTypeDecl "u_base" "userobject" Nothing)
                    [ Located 1 (BsLocalVar [] (PtPrimitive "string") "ai_count" Nothing) ] ] }
              sfMid = emptySrFile
                { srTypeBlocks = [ TypeBlock (mkTypeDecl "u_mid" "u_base" Nothing)
                    [ Located 1 (BsLocalVar [] (PtPrimitive "long") "ai_count" Nothing) ] ] }
              wsEnv = buildWorkspaceEnv [sf, sfBase, sfMid]
              idx   = buildControlIndex [sf, sfBase, sfMid]
          case extractVarRefs wsEnv idx "test.srw" "w_test" sf of
            [_receiver, tail_] ->
              (rvrTargetObject tail_, rvrDeclaredType tail_) @?= (Just "u_mid", Just "long")
            other -> assertFailure ("expected 2 refs (one per segment), got " ++ show (length other))

      , testCase "declared_type: local/param/instance/global single-segment reads all populate it" $ do
          let body = [ localVarStmt "ll_x" (PtPrimitive "integer") 5
                     , Located 6 (BsReturn (Just (ExLvalue (Lvalue [LvSegment "ll_x" Nothing]))))
                     , Located 7 (BsReturn (Just (ExLvalue (Lvalue [LvSegment "al_row" Nothing]))))
                     , Located 8 (BsReturn (Just (ExLvalue (Lvalue [LvSegment "ai_flag" Nothing]))))
                     , Located 9 (BsReturn (Just (ExLvalue (Lvalue [LvSegment "ig_name" Nothing]))))
                     ]
              sf = emptySrFile
                { srTypeBlocks = [ TypeBlock (mkTypeDecl "w_test" "window" Nothing)
                    [ Located 1 (BsLocalVar [] (PtPrimitive "boolean") "ai_flag" Nothing) ] ]
                , srVariables = [ VariablesBlock GlobalVars [ VarDecl [] "string" (SourceSpan 1 1 1 1) "ig_name" ] ]
                , srFunctions = [ mkFn "f_go" "long al_row" body ]
                }
              wsEnv = buildWorkspaceEnv [sf]
          case extractVarRefs wsEnv emptyControlIdx "test.srw" "w_test" sf of
            [local_, param_, instance_, global_] -> do
              rvrDeclaredType local_    @?= Just "integer"
              rvrDeclaredType param_    @?= Just "long"
              rvrDeclaredType instance_ @?= Just "boolean"
              rvrDeclaredType global_   @?= Just "string"
            other -> assertFailure ("expected 4 refs, got " ++ show (length other))

      , testCase "single segment matching nothing in scope -> unresolved" $ do
          let sf = emptySrFile { srFunctions = [ mkFn "f_go" ""
                    [ Located 5 (BsReturn (Just (ExLvalue (Lvalue [LvSegment "ls_unknown" Nothing])))) ] ] }
          case extractVarRefs emptyWsEnv emptyControlIdx "test.srw" "w_test" sf of
            [r] -> rvrKind r @?= "unresolved"
            other -> assertFailure ("expected 1 ref, got " ++ show (length other))
      ]

  , testGroup "ancestorChain"
      [ testCase "walks a self-consistently-cased map even when the query key's own casing differs" $ do
          let inh = Map.fromList [("w_child", "w_base")]
          ancestorChain "W_Child" inh @?= ["W_Child", "w_base"]
      ]

  , testGroup "buildProcMap"
      [ testCase "includes function names" $ do
          let sf = emptySrFile
                { srTypeBlocks = [ mkTB "w_test" "window" ]
                , srFunctions  = [ mkFn "f_go" "" [] ]
                }
              pm = buildProcMap [sf]
          identSetMember "f_go" (maybe identSetEmpty snd (identMapLookup "w_test" pm)) @?= True
      ]

  , testGroup "resolveVirtual"
      [ testCase "recovers the ancestor's own declared casing as target_object even when the child's inherits-map value spells it differently" $ do
          let sf = emptySrFile
                { srTypeBlocks = [ mkTB "w_base" "window" ]
                , srFunctions  = [ mkFn "of_help" "" [] ]
                }
              pm  = buildProcMap [sf]
              -- 'w_child' spells its own ancestor "W_BASE" -- differently
              -- cased than 'w_base's own declaration, the exact procMap-
              -- outer-key scenario this fix targets.
              inh = Map.fromList [(mkIdent "w_child", mkIdent "W_BASE")]
          resolveVirtual (mkIdent "of_help") (mkIdent "w_child") pm inh
            @?= (Just "w_base", Just "of_help", "inherited", "high")
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
          case resolveTypes [lv] identSetEmpty identSetEmpty of
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
          case resolveTypes [lv] (identSetSingleton (mkIdent "w_main")) identSetEmpty of
            [rt] -> do
              rtKind rt   @?= "object"
              rtTarget rt @?= Just "w_main"
            other -> assertFailure ("expected 1 result, got " ++ show (length other))
      ]

  , testGroup "resolveGlobalTypes"
      [ testCase "primitive instance var -> primitive kind, instance scope" $ do
          let gv = GlobalVar
                { gvFile   = "t.srw"
                , gvObject = "w_t"
                , gvName   = "ii_count"
                , gvType   = "integer"
                , gvMods   = []
                , gvPbType = PtPrimitive "integer"
                }
          case resolveGlobalTypes [gv] identSetEmpty identSetEmpty of
            [rt] -> do
              rtKind rt     @?= "primitive"
              rtTarget rt   @?= Nothing
              rtScope rt    @?= "instance"
              rtProcName rt @?= ""
            other -> assertFailure ("expected 1 result, got " ++ show (length other))

      , testCase "object-typed instance var -> object kind with target, instance scope" $ do
          let gv = GlobalVar
                { gvFile   = "t.srw"
                , gvObject = "w_t"
                , gvName   = "iw_child"
                , gvType   = "w_main"
                , gvMods   = []
                , gvPbType = PtUserDefined "w_main"
                }
          case resolveGlobalTypes [gv] (identSetSingleton (mkIdent "w_main")) identSetEmpty of
            [rt] -> do
              rtKind rt   @?= "object"
              rtTarget rt @?= Just "w_main"
              rtScope rt  @?= "instance"
            other -> assertFailure ("expected 1 result, got " ++ show (length other))

      , testCase "empty input yields no results" $
          resolveGlobalTypes [] identSetEmpty identSetEmpty @?= []
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
                , csReceiverObject = Nothing
                , csToNameSpan     = Nothing
                }
              pm = identMapFromList [("w_t", identSetSingleton "f_helper")]
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
                , csReceiverObject = Nothing
                , csToNameSpan     = Nothing
                }
              pm  = identMapFromList
                      [ ("w_child",  identSetEmpty)
                      , ("w_parent", identSetSingleton "f_base")
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
                , csReceiverObject = Nothing
                , csToNameSpan     = Nothing
                }
          case resolveCalls [site] identMapEmpty Map.empty Set.empty Set.empty of
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
                , csReceiverObject = Nothing
                , csToNameSpan     = Nothing
                }
              pm = identMapFromList
                     [ ("w_main", identSetEmpty)
                     , ("trn",    identSetSingleton "trn")
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
                , csReceiverObject = Nothing
                , csToNameSpan     = Nothing
                }
              pm = identMapFromList
                     [ ("w_t",     identSetEmpty)
                     , ("w_other", identSetSingleton "f_helper")
                     , ("w_third", identSetSingleton "f_helper")
                     ]
          case resolveCalls [site] pm Map.empty Set.empty Set.empty of
            [rc] -> rcKind rc @?= "unresolved"
            other -> assertFailure ("expected 1 result, got " ++ show (length other))

      , testCase "ExMethodCall with resolved receiver_object → virtual high (Plan 195 Phase D)" $ do
          -- 'csReceiverObject' is populated at extraction time (see
          -- 'extractCallSites'); 'resolveOne' just walks it through the same
          -- 'resolveVirtual' every other call kind already uses.
          let site = CallSite
                { csFile     = "t.srw"
                , csObject   = "w_t"
                , csFromProc = "f_go"
                , csToName   = "f_method"
                , csCallType = "ExMethodCall"
                , csLine     = Nothing
                , csReceiverObject = Just "w_other"
                , csToNameSpan     = Nothing
                }
              pm = identMapFromList
                     [ ("w_t",     identSetEmpty)
                     , ("w_other", identSetSingleton "f_method")
                     ]
          case resolveCalls [site] pm Map.empty Set.empty Set.empty of
            [rc] -> do
              rcKind rc         @?= "virtual"
              rcConfidence rc   @?= "high"
              rcTargetObject rc @?= Just "w_other"
              rcTargetProc   rc @?= Just "f_method"
            other -> assertFailure ("expected 1 result, got " ++ show (length other))

      , testCase "ExMethodCall with resolved receiver_object whose ancestor declares the method → inherited high" $ do
          let site = CallSite
                { csFile     = "t.srw"
                , csObject   = "w_t"
                , csFromProc = "f_go"
                , csToName   = "f_method"
                , csCallType = "ExMethodCall"
                , csLine     = Nothing
                , csReceiverObject = Just "w_child"
                , csToNameSpan     = Nothing
                }
              pm = identMapFromList
                     [ ("w_child",  identSetEmpty)
                     , ("w_parent", identSetSingleton "f_method")
                     ]
              inh = Map.singleton "w_child" "w_parent"
          case resolveCalls [site] pm inh Set.empty Set.empty of
            [rc] -> do
              rcKind rc         @?= "inherited"
              rcTargetObject rc @?= Just "w_parent"
            other -> assertFailure ("expected 1 result, got " ++ show (length other))

      , testCase "ExMethodCall with unresolvable receiver (csReceiverObject = Nothing) → unresolved" $ do
          let site = CallSite
                { csFile     = "t.srw"
                , csObject   = "w_t"
                , csFromProc = "f_go"
                , csToName   = "retrieve"
                , csCallType = "ExMethodCall"
                , csLine     = Nothing
                , csReceiverObject = Nothing
                , csToNameSpan     = Nothing
                }
          case resolveCalls [site] identMapEmpty Map.empty Set.empty Set.empty of
            [rc] -> rcKind rc @?= "unresolved"
            other -> assertFailure ("expected 1 result, got " ++ show (length other))

      , testCase "ExMethodCall with resolved receiver_object but method not found → unresolved" $ do
          let site = CallSite
                { csFile     = "t.srw"
                , csObject   = "w_t"
                , csFromProc = "f_go"
                , csToName   = "ghost_method"
                , csCallType = "ExMethodCall"
                , csLine     = Nothing
                , csReceiverObject = Just "w_other"
                , csToNameSpan     = Nothing
                }
              pm = identMapFromList [("w_other", identSetEmpty)]
          case resolveCalls [site] pm Map.empty Set.empty Set.empty of
            [rc] -> rcKind rc @?= "unresolved"
            other -> assertFailure ("expected 1 result, got " ++ show (length other))

      , testCase "bare call written in different case than its declaration → virtual high, declared casing recovered" $ do
          let site = CallSite
                { csFile     = "t.srw"
                , csObject   = "w_t"
                , csFromProc = "f_go"
                , csToName   = "F_Helper"
                , csCallType = "ExCall"
                , csLine     = Nothing
                , csReceiverObject = Nothing
                , csToNameSpan     = Nothing
                }
              pm = identMapFromList [("w_t", identSetFromList ["f_helper"])]
          case resolveCalls [site] pm Map.empty Set.empty Set.empty of
            [rc] -> do
              rcKind rc         @?= "virtual"
              rcConfidence rc   @?= "high"
              rcTargetProc   rc @?= Just "f_helper"
            other -> assertFailure ("expected 1 result, got " ++ show (length other))

      , testCase "ExMethodCall with receiver_object/method in different case than declared → virtual high, declared casing recovered" $ do
          let site = CallSite
                { csFile     = "t.srw"
                , csObject   = "w_t"
                , csFromProc = "f_go"
                , csToName   = "F_Method"
                , csCallType = "ExMethodCall"
                , csLine     = Nothing
                , csReceiverObject = Just "W_Other"
                , csToNameSpan     = Nothing
                }
              pm = identMapFromList
                     [ ("w_t",     identSetEmpty)
                     , ("w_other", identSetFromList ["f_method"])
                     ]
          case resolveCalls [site] pm Map.empty Set.empty Set.empty of
            [rc] -> do
              rcKind rc         @?= "virtual"
              rcConfidence rc   @?= "high"
              rcTargetObject rc @?= Just "w_other"
              rcTargetProc   rc @?= Just "f_method"
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
                , csReceiverObject = Nothing
                , csToNameSpan     = Nothing
                }
          case resolveCalls [site] identMapEmpty Map.empty (Set.singleton "messagebox") Set.empty of
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
                , csReceiverObject = Nothing
                , csToNameSpan     = Nothing
                }
          case resolveCalls [site] identMapEmpty Map.empty Set.empty (Set.singleton "retrieve") of
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
                , csReceiverObject = Nothing
                , csToNameSpan     = Nothing
                }
              pm = identMapFromList [("w_t", identSetSingleton "f_helper")]
          case resolveCalls [site] pm Map.empty Set.empty Set.empty of
            [rc] -> rcKind rc @?= "virtual"
            other -> assertFailure ("expected 1 result, got " ++ show (length other))
      ]
  , testGroup "extractDwCallSites"
    [ testCase "empty DW yields no call sites" $ do
        case parseDataWindow dwMin of
          Left err -> assertFailure ("parse error: " <> T.unpack err)
          Right dw -> extractDwCallSites emptyWsEnv emptyControlIdx "test.srd" "dw_test" dw @?= []

    , testCase "compute expression ExCall becomes a call site" $ do
        let src = dwMin <> "\ncompute(band=summary name=c1 x=\"0\" y=\"0\" width=\"100\" height=\"40\" visible=\"1\" expression=\"fn_foo()\" )"
        case parseDataWindow src of
          Left err -> assertFailure ("parse error: " <> T.unpack err)
          Right dw -> case extractDwCallSites emptyWsEnv emptyControlIdx "test.srd" "dw_test" dw of
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
            let names = map csToName (extractDwCallSites emptyWsEnv emptyControlIdx "test.srd" "dw_test" dw)
            in  names @?= ["fn_a", "fn_b"]

    , testCase "format ExCall after ~t separator becomes a call site" $ do
        let src = dwMin <> "\ncompute(band=summary name=c1 x=\"0\" y=\"0\" width=\"100\" height=\"40\" visible=\"1\" expression=\"fn_val()\" format=\"[GENERAL]~tfn_mask()\" )"
        case parseDataWindow src of
          Left err -> assertFailure ("parse error: " <> T.unpack err)
          Right dw ->
            let names = map csToName (extractDwCallSites emptyWsEnv emptyControlIdx "test.srd" "dw_test" dw)
            in  names @?= ["fn_val", "fn_mask"]
    ]

  , testGroup "extractDwVarRefs"
    [ testCase "empty DW yields no var refs" $ do
        case parseDataWindow dwMin of
          Left err -> assertFailure ("parse error: " <> T.unpack err)
          Right dw -> extractDwVarRefs emptyWsEnv emptyControlIdx "test.srd" "dw_test" dw @?= []

    , testCase "compute expression identifier becomes a read var ref" $ do
        let src = dwMin <> "\ncompute(band=summary name=c1 x=\"0\" y=\"0\" width=\"100\" height=\"40\" visible=\"1\" expression=\"li_count\" )"
        case parseDataWindow src of
          Left err -> assertFailure ("parse error: " <> T.unpack err)
          Right dw -> case extractDwVarRefs emptyWsEnv emptyControlIdx "test.srd" "dw_test" dw of
            [r] -> (rvrName r, rvrAccess r) @?= ("li_count", "read")
            other -> assertFailure ("expected 1 var ref, got " <> show (length other))
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
              , srVariables = [VariablesBlock GlobalVars
                  [VarDecl [] "long" (SourceSpan 1 1 1 1) "g_counter"]]
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
              , srVariables = [], srGlobalInstances = []
              , srTypeBlocks = [], srOnBlocks = [], srEvents = []
              , srFunctions = [], srSubroutines = []
              }
        in extractGlobalVars "w.srf" "w_test" sf @?= []

    , testCase "forward-declared global instance is extracted" $
        let sf = emptySrFile
              { srForward = Just ForwardBlock
                  { fwdTypes = []
                  , fwdInstances = [GlobalInstance "transaction" (SourceSpan 1 1 1 1) "sqlca"]
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
              { tbDecl = mkTypeDecl "dw_dest" "datawindow" (Just "w_dw_copy")
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
              { tbDecl = mkTypeDecl "dw" "w_list`dw" (Just "w_misth_final_details_list")
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
              { tbDecl = mkTypeDecl "dw" "datawindow" (Just "w_test")
              , tbBody = [widthVar]
              }
            sf = emptySrFile { srTypeBlocks = [tb] }
        in extractDwControlBindings "w.srw" sf @?= []

    , testCase "outer type block (no within) binds as control name this" $
        let dataObjectVar = Located 1 BsLocalVar
              { varMods = [], varType = PtPrimitive "string"
              , varName = "dataobject", varInit = Just (ExStr "d_self") }
            tb = TypeBlock
              { tbDecl = mkTypeDecl "w_selfdw" "window" Nothing
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
            result = resolveTypes [lv] identSetEmpty identSetEmpty
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
