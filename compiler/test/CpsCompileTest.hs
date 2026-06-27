module CpsCompileTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr         (BinOp (..), Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Located      (Located (..))
import PB.AST.Type         (PbType (..))
import PB.Lexing.Lexer        (tokenizeLine, LexLine (..))
import PB.Lexing.Token        (Token (..), TokenKind (..), SourceSpan (..))
import PB.Analysis.CpsCompile
import PB.Analysis.CallClassify (CallKind (..), classifyExpr, effectName)
import PB.Pipeline.Preprocess (LogicalLine (..))
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T
import Test.Tasty           (TestTree, testGroup)
import Test.Tasty.HUnit     (assertBool, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Helpers

at :: Int -> a -> Located a
at n x = Located n x

lv1 :: Text -> Lvalue
lv1 n = Lvalue [LvSegment n Nothing]

lv2 :: Text -> Text -> Lvalue
lv2 a b = Lvalue [LvSegment a Nothing, LvSegment b Nothing]

tok :: Text -> Token
tok t = case lexResult (tokenizeLine ll) of
  Right (tk:_) -> tk
  _            -> Token TkIdent t (SourceSpan 1 1 1)
  where ll = LogicalLine t 1 1

-- dw.retrieve()  (2-segment ExCall)
retrieveCall :: Expr
retrieveCall =
  ExCall { callee = lv2 "dw" "retrieve", callArgs = [] }

-- open(w_test)
openCall :: Expr
openCall =
  ExCall { callee = lv1 "open", callArgs = [[tok "w_test"]] }

-- messagebox("hi")
pureCall :: Expr
pureCall =
  ExCall { callee = lv1 "messagebox", callArgs = [[tok "\"hi\""]] }

-- ---------------------------------------------------------------------------
-- Convenience env builders

emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv
  { steGlobal    = Map.empty
  , steInstance  = Map.empty
  , steLocal     = Map.empty
  , steHierarchy = Map.empty
  }

-- | Single var → user-defined type, no inheritance.
varEnv :: Text -> Text -> ScopedTypeEnv
varEnv v t = ScopedTypeEnv
  { steGlobal    = Map.singleton (T.toLower v) (PtUserDefined t)
  , steInstance  = Map.empty
  , steLocal     = Map.empty
  , steHierarchy = Map.empty
  }

-- | Single var + inheritance chain.
varEnvInh :: [(Text, Text)] -> [(Text, Text)] -> ScopedTypeEnv
varEnvInh vars inh = ScopedTypeEnv
  { steGlobal    = Map.fromList [(T.toLower v, PtUserDefined t) | (v, t) <- vars]
  , steInstance  = Map.empty
  , steLocal     = Map.empty
  , steHierarchy = Map.fromList inh
  }

dwEnv :: ScopedTypeEnv
dwEnv = varEnv "dw" "datawindow"

transEnv :: ScopedTypeEnv
transEnv = varEnv "sqlca" "transaction"

noEnv :: ScopedTypeEnv
noEnv = emptyEnv

-- | Compile with no user-fn registry (the common case in these tests).
compile :: ScopedTypeEnv -> [Located BodyStmt] -> CpsGraph
compile env = compileProcedure env Set.empty

-- | Compile with a user-fn registry (for Item 3 tests).
compileWith :: ScopedTypeEnv -> [Text] -> [Located BodyStmt] -> CpsGraph
compileWith env fns = compileProcedure env (Set.fromList (map T.toLower fns))

-- ---------------------------------------------------------------------------

tests :: TestTree
tests = testGroup "CpsCompile"

  -- ------------------------------------------------------------------
  -- Existing structural tests (updated to new compileProcedure signature)

  [ testCase "empty body → single CpsReturn at entry 0" $ do
      let g = compile noEnv []
      cgEntry g @?= 0
      length (cgNodes g) @?= 1
      case cgNodes g of
        [CpsReturn Nothing] -> pure ()
        ns                  -> assertBool ("expected [CpsReturn Nothing], got: " <> show ns) False

  , testCase "single BsAssign → assign node + return, entry ≠ 0" $ do
      let stmt = at 10 (BsAssign (lv1 "x") (ExInt "1"))
          g    = compile noEnv [stmt]
      length (cgNodes g) @?= 2
      assertBool "entry should be > 0" (cgEntry g > 0)
      case cgNodes g of
        [CpsReturn {}, CpsAssign { anVar = "x" }] -> pure ()
        ns -> assertBool ("unexpected nodes: " <> show ns) False

  , testCase "BsCall retrieve with DataWindow type → CpsSuspend retrieve:dw" $ do
      let stmt = at 5 (BsCall retrieveCall)
          g    = compile dwEnv [stmt]
      let suNodes = [ n | n@CpsSuspend {} <- cgNodes g ]
      assertBool "expected at least one CpsSuspend" (not (null suNodes))
      case suNodes of
        (s:_) -> suEffect s @?= "retrieve:dw"
        _     -> pure ()

  , testCase "BsCall retrieve with DataWindow type → listed in suspensionPoints" $ do
      let stmt = at 5 (BsCall retrieveCall)
          g    = compile dwEnv [stmt]
      assertBool "suspensionPoints should be non-empty" (not (null (cgSuspensionPoints g)))

  , testCase "BsCall open → CpsSuspend with effect open" $ do
      let stmt = at 7 (BsCall openCall)
          g    = compile noEnv [stmt]
      let suNodes = [ n | n@CpsSuspend {} <- cgNodes g ]
      assertBool "expected CpsSuspend" (not (null suNodes))
      case suNodes of
        (s:_) -> suEffect s @?= "open"
        _     -> pure ()

  , testCase "pure BsCall → CpsCall (not suspend)" $ do
      let stmt = at 3 (BsCall pureCall)
          g    = compile noEnv [stmt]
      let suNodes = [ n | n@CpsSuspend {} <- cgNodes g ]
      let caNodes = [ n | n@CpsCall {} <- cgNodes g ]
      suNodes @?= []
      assertBool "expected CpsCall" (not (null caNodes))

  , testCase "BsIf → CpsBranch node" $ do
      let thenS = [at 2 (BsAssign (lv1 "x") (ExInt "1"))]
          stmt  = at 1 (BsIf (IfStmt (ExBool True) thenS [] Nothing))
          g     = compile noEnv [stmt]
      let brNodes = [ n | n@CpsBranch {} <- cgNodes g ]
      assertBool "expected CpsBranch" (not (null brNodes))

  , testCase "BsAssign on line 42 → 42 appears in sourceMap" $ do
      let stmt = at 42 (BsAssign (lv1 "x") (ExInt "1"))
          g    = compile noEnv [stmt]
      let lines_ = map snd (cgSourceMap g)
      assertBool "line 42 should be in sourceMap" (42 `elem` lines_)

  -- ------------------------------------------------------------------
  -- Type-guided classification

  , testGroup "type-guided classification"

    [ testCase "dw.retrieve() with DataWindow type → SuspendCall retrieve:dw" $
        classifyExpr dwEnv
          (ExCall { callee = lv2 "dw" "retrieve", callArgs = [] })
          @?= SuspendCall

    , testCase "dw.retrieve() without type info → PureCall (conservative)" $
        classifyExpr noEnv
          (ExCall { callee = lv2 "dw" "retrieve", callArgs = [] })
          @?= PureCall

    , testCase "unknown_var.retrieve() without type info → PureCall" $
        classifyExpr noEnv
          (ExCall { callee = lv2 "unknown_var" "retrieve", callArgs = [] })
          @?= PureCall

    , testCase "dw.update() with DataWindow type → SuspendCall executeSql" $
        classifyExpr dwEnv
          (ExCall { callee = lv2 "dw" "update", callArgs = [] })
          @?= SuspendCall

    , testCase "dw.delete() with DataWindow type → SuspendCall executeSql" $
        classifyExpr dwEnv
          (ExCall { callee = lv2 "dw" "delete", callArgs = [] })
          @?= SuspendCall

    , testCase "dw.reset() with DataWindow type → SuspendCall executeSql" $
        classifyExpr dwEnv
          (ExCall { callee = lv2 "dw" "reset", callArgs = [] })
          @?= SuspendCall

    , testCase "dw.settransobject() with DataWindow type → PureCall (setup only)" $
        classifyExpr dwEnv
          (ExCall { callee = lv2 "dw" "settransobject", callArgs = [] })
          @?= PureCall

    , testCase "sqlca.commit() with Transaction type → SuspendCall executeSql" $
        classifyExpr transEnv
          (ExCall { callee = lv2 "sqlca" "commit", callArgs = [] })
          @?= SuspendCall

    , testCase "sqlca.rollback() with Transaction type → SuspendCall executeSql" $
        classifyExpr transEnv
          (ExCall { callee = lv2 "sqlca" "rollback", callArgs = [] })
          @?= SuspendCall

    , testCase "sqlca.connect() with Transaction type → SuspendCall executeSql" $
        classifyExpr transEnv
          (ExCall { callee = lv2 "sqlca" "connect", callArgs = [] })
          @?= SuspendCall

    , testCase "sqlca.disconnect() with Transaction type → SuspendCall executeSql" $
        classifyExpr transEnv
          (ExCall { callee = lv2 "sqlca" "disconnect", callArgs = [] })
          @?= SuspendCall

    , testCase "fn_retrievechild() always SuspendCall (builtin)" $
        classifyExpr noEnv
          (ExCall { callee = lv1 "fn_retrievechild", callArgs = [] })
          @?= SuspendCall

    , testCase "open() always SuspendCall open (builtin)" $
        classifyExpr noEnv
          (ExCall { callee = lv1 "open", callArgs = [[tok "w_test"]] })
          @?= SuspendCall

    , testCase "opensheet() always SuspendCall open (builtin)" $
        classifyExpr noEnv
          (ExCall { callee = lv1 "opensheet", callArgs = [] })
          @?= SuspendCall

    , testCase "close() always SuspendCall close (builtin)" $
        classifyExpr noEnv
          (ExCall { callee = lv1 "close", callArgs = [] })
          @?= SuspendCall

    , testCase "datastore receiver treated same as datawindow → SuspendCall retrieve:ds" $
        classifyExpr (varEnv "ds" "datastore")
          (ExCall { callee = lv2 "ds" "retrieve", callArgs = [] })
          @?= SuspendCall

    , testCase "effect name: open() → open" $
        effectName (ExCall { callee = lv1 "open", callArgs = [[tok "w_test"]] }) []
          @?= "open"

    , testCase "effect name: dw.retrieve() → retrieve:dw" $
        effectName (ExCall { callee = lv2 "dw" "retrieve", callArgs = [] }) []
          @?= "retrieve:dw"

    , testCase "effect name: fn_retrievechild('kodperiod') → retrieve:child_kodperiod:adw" $
        effectName (ExCall { callee   = lv1 "fn_retrievechild"
                           , callArgs = [[tok "adw"], [tok "\"kodperiod\""], [tok "gs_kodxrisi"]] })
                   [ExLvalue (lv1 "adw"), ExStr "kodperiod"]
          @?= "retrieve:child_kodperiod:adw"

    , testCase "InheritGraph: user type inheriting datawindow → SuspendCall retrieve:ids_data" $
        classifyExpr (varEnvInh [("ids_data", "n_cst_ds")] [("n_cst_ds", "datastore")])
          (ExCall { callee = lv2 "ids_data" "retrieve", callArgs = [] })
          @?= SuspendCall

    , testCase "InheritGraph: user type NOT inheriting DW → PureCall" $
        classifyExpr (varEnvInh [("myobj", "n_some_struct")] [("n_some_struct", "structure")])
          (ExCall { callee = lv2 "myobj" "retrieve", callArgs = [] })
          @?= PureCall
    ]

  , testGroup "cross-file InheritGraph"
    [ testCase "two-step chain: my_ds → n_cst_ds → datastore → SuspendCall retrieve:my_ds" $
        classifyExpr (varEnvInh [("my_ds", "n_cst_ds")]
                                [("n_cst_ds", "datastore"), ("datastore", "datawindow")])
          (ExCall { callee = lv2 "my_ds" "retrieve", callArgs = [] })
          @?= SuspendCall

    , testCase "cycle guard: chain with loop does not hang" $
        classifyExpr (varEnvInh [("x", "a")] [("a", "b"), ("b", "a")])
          (ExCall { callee = lv2 "x" "retrieve", callArgs = [] })
          @?= PureCall

    , testCase "deep chain (5 levels): still resolves to datawindow → SuspendCall retrieve:deep" $
        classifyExpr (varEnvInh [("deep", "l5")]
                                [ ("l5", "l4"), ("l4", "l3"), ("l3", "l2")
                                , ("l2", "l1"), ("l1", "datawindow") ])
          (ExCall { callee = lv2 "deep" "retrieve", callArgs = [] })
          @?= SuspendCall

    , testCase "unknown type not in chain → PureCall" $
        classifyExpr (varEnvInh [("mystery", "unknown_type")] [("n_cst_ds", "datastore")])
          (ExCall { callee = lv2 "mystery" "retrieve", callArgs = [] })
          @?= PureCall
    ]

  , testGroup "classifyExpr stdlib hierarchy"
    [ testCase "user DW subtype over full stdlib chain: retrieve → SuspendCall retrieve:rpt" $
        -- Simulates stdlib: my_report_dw → datawindow → nonvisualobject → powerobject
        -- Old code returned "powerobject" from lookupBaseType → Pure (bug)
        classifyExpr (varEnvInh [("rpt", "my_report_dw")]
                                [ ("my_report_dw", "datawindow")
                                , ("datawindow", "nonvisualobject")
                                , ("nonvisualobject", "powerobject")
                                ])
          (ExCall { callee = lv2 "rpt" "retrieve", callArgs = [] })
          @?= SuspendCall

    , testCase "direct PtPrimitive datawindow with stdlib parents: retrieve → SuspendCall retrieve:dw1" $
        -- PtPrimitive "datawindow" declared var; stdlib adds datawindow → nonvisualobject
        -- Old code: lookupBaseType walks to "powerobject" → Pure (bug)
        let env = ScopedTypeEnv
              { steGlobal    = Map.singleton "dw1" (PtPrimitive "datawindow")
              , steInstance  = Map.empty
              , steLocal     = Map.empty
              , steHierarchy = Map.fromList
                  [ ("datawindow", "nonvisualobject")
                  , ("nonvisualobject", "powerobject")
                  ]
              }
        in classifyExpr env
             (ExCall { callee = lv2 "dw1" "retrieve", callArgs = [] })
             @?= SuspendCall

    , testCase "powerobject var: retrieve → PureCall (not a DW descendant)" $
        let env = ScopedTypeEnv
              { steGlobal    = Map.singleton "obj" (PtPrimitive "powerobject")
              , steInstance  = Map.empty
              , steLocal     = Map.empty
              , steHierarchy = Map.empty
              }
        in classifyExpr env
             (ExCall { callee = lv2 "obj" "retrieve", callArgs = [] })
             @?= PureCall

    , testCase "transaction with stdlib chain: commit → SuspendCall executeSql" $
        -- Old code: lookupBaseType walks transaction → nonvisualobject → powerobject
        -- → isTransType "powerobject" = False → Pure (bug)
        let env = ScopedTypeEnv
              { steGlobal    = Map.singleton "trans" (PtPrimitive "transaction")
              , steInstance  = Map.empty
              , steLocal     = Map.empty
              , steHierarchy = Map.fromList
                  [ ("transaction", "nonvisualobject")
                  , ("nonvisualobject", "powerobject")
                  ]
              }
        in classifyExpr env
             (ExCall { callee = lv2 "trans" "commit", callArgs = [] })
             @?= SuspendCall
    ]

  , testGroup "ExMethodCall classification"
    [ testCase "ExMethodCall with ExLvalue receiver (datawindow) → SuspendCall retrieve:dw" $
        classifyExpr (varEnv "dw" "datawindow")
          (ExMethodCall (ExLvalue (lv1 "dw")) "retrieve" [])
          @?= SuspendCall

    , testCase "ExMethodCall with ExLvalue receiver (transaction) → SuspendCall executeSql" $
        classifyExpr (varEnv "sqlca" "transaction")
          (ExMethodCall (ExLvalue (lv1 "sqlca")) "commit" [])
          @?= SuspendCall

    , testCase "ExMethodCall with ExCall receiver (single-segment callee in env) → SuspendCall retrieve:get_dw" $
        classifyExpr (varEnv "get_dw" "datawindow")
          (ExMethodCall (ExCall (lv1 "get_dw") []) "retrieve" [])
          @?= SuspendCall

    , testCase "ExMethodCall with ExCall receiver (multi-segment callee) → PureCall" $
        classifyExpr (varEnv "ns_func.get_dw" "datawindow")
          (ExMethodCall (ExCall (lv2 "ns_func" "get_dw") []) "retrieve" [])
          @?= PureCall

    , testCase "ExMethodCall settransobject on datastore → PureCall (setup only)" $
        classifyExpr (varEnv "ids" "datastore")
          (ExMethodCall (ExLvalue (lv1 "ids")) "settransobject" [])
          @?= PureCall

    , testCase "ExMethodCall rowscopy on datastore → SuspendCall executeSql" $
        classifyExpr (varEnv "ids" "datastore")
          (ExMethodCall (ExLvalue (lv1 "ids")) "rowscopy" [])
          @?= SuspendCall

    , testCase "ExMethodCall describe on datawindow → PureCall (read-only)" $
        classifyExpr (varEnv "dw" "datawindow")
          (ExMethodCall (ExLvalue (lv1 "dw")) "describe" [])
          @?= PureCall
    ]

  -- ------------------------------------------------------------------
  -- Gap 1: BsAugAssign / BsInc / BsDec (Plan 112)

  , testGroup "Gap 1 – augmented assignment"

    [ testCase "BsAugAssign add emits CpsAssign with ExBinOp BopAdd" $ do
        let stmt = at 5 (BsAugAssign [tok "x"] AugAdd [tok "y"])
            g    = compile noEnv [stmt]
            assignNodes = [ n | n@CpsAssign {} <- cgNodes g ]
        assertBool "expected CpsAssign for BsAugAssign" (not (null assignNodes))
        case assignNodes of
          (n:_) -> do
            anVar n @?= "x"
            case anRhs n of
              ExBinOp { op = BopAdd } -> pure ()
              e -> assertBool ("expected ExBinOp BopAdd, got: " <> show e) False
          [] -> assertBool "no CpsAssign emitted" False

    , testCase "BsAugAssign sub emits CpsAssign with ExBinOp BopSub" $ do
        let stmt = at 5 (BsAugAssign [tok "x"] AugSub [tok "y"])
            g    = compile noEnv [stmt]
            assignNodes = [ n | n@CpsAssign {} <- cgNodes g ]
        assertBool "expected CpsAssign for BsAugAssign sub" (not (null assignNodes))
        case assignNodes of
          (n:_) -> case anRhs n of
            ExBinOp { op = BopSub } -> pure ()
            e -> assertBool ("expected ExBinOp BopSub, got: " <> show e) False
          [] -> assertBool "no CpsAssign emitted" False

    , testCase "BsInc emits CpsAssign with ExBinOp BopAdd ExInt 1" $ do
        let stmt = at 3 (BsInc [tok "i"])
            g    = compile noEnv [stmt]
            assignNodes = [ n | n@CpsAssign {} <- cgNodes g ]
        assertBool "expected CpsAssign for BsInc" (not (null assignNodes))
        case assignNodes of
          (n:_) -> do
            anVar n @?= "i"
            anRhs n @?= ExBinOp { lhs = ExLvalue (lv1 "i"), op = BopAdd, rhs = ExInt "1" }
          [] -> assertBool "no CpsAssign emitted" False

    , testCase "BsDec emits CpsAssign with ExBinOp BopSub ExInt 1" $ do
        let stmt = at 3 (BsDec [tok "i"])
            g    = compile noEnv [stmt]
            assignNodes = [ n | n@CpsAssign {} <- cgNodes g ]
        assertBool "expected CpsAssign for BsDec" (not (null assignNodes))
        case assignNodes of
          (n:_) -> do
            anVar n @?= "i"
            anRhs n @?= ExBinOp { lhs = ExLvalue (lv1 "i"), op = BopSub, rhs = ExInt "1" }
          [] -> assertBool "no CpsAssign emitted" False

    , testCase "BsDestroy emits CpsAssign with ExNull (Plan 115 item 1)" $ do
        let stmt = at 4 (BsDestroy (lv1 "obj"))
            g    = compile noEnv [stmt]
            assignNodes = [ n | n@CpsAssign {} <- cgNodes g ]
        assertBool "expected CpsAssign for BsDestroy" (not (null assignNodes))
        case assignNodes of
          (n:_) -> do
            anVar n @?= "obj"
            anRhs n @?= ExNull
          [] -> assertBool "no CpsAssign emitted" False
    ]

  -- ------------------------------------------------------------------
  -- Gap 2: BsExit / BsContinue (Plan 112)

  , testGroup "Gap 2 – exit and continue"

    [ testCase "BsExit outside loop falls through (no CpsGoto)" $ do
        let stmt = at 1 BsExit
            g    = compile noEnv [stmt]
            gotos = [ n | n@CpsGoto {} <- cgNodes g ]
        gotos @?= []

    , testCase "BsExit inside for loop emits CpsGoto to exit PC" $ do
        let exitStmt = at 2 BsExit
            forStmt  = at 1 (BsFor (ForStmt (lv1 "i") (ExInt "1") (ExInt "10") Nothing [exitStmt]))
            g        = compile noEnv [forStmt]
            nodes    = cgNodes g
            gotos    = [ n | n@CpsGoto {} <- nodes ]
        assertBool "expected CpsGoto for BsExit" (not (null gotos))
        case gotos of
          [CpsGoto { goTarget = tgt }] ->
            assertBool ("expected CpsReturn at exit target PC " <> show tgt)
                       (case drop tgt nodes of { (CpsReturn {} : _) -> True; _ -> False })
          _ -> assertBool ("unexpected goto count " <> show (length gotos)) False

    , testCase "BsContinue inside for loop emits CpsGoto to increment PC" $ do
        let contStmt = at 2 BsContinue
            forStmt  = at 1 (BsFor (ForStmt (lv1 "i") (ExInt "1") (ExInt "10") Nothing [contStmt]))
            g        = compile noEnv [forStmt]
            nodes    = cgNodes g
            gotos    = [ n | n@CpsGoto {} <- nodes ]
        assertBool "expected CpsGoto for BsContinue" (not (null gotos))
        case gotos of
          [CpsGoto { goTarget = tgt }] ->
            assertBool ("expected CpsAssign (increment) at header PC " <> show tgt)
                       (case drop tgt nodes of { (CpsAssign {} : _) -> True; _ -> False })
          _ -> assertBool ("unexpected goto count " <> show (length gotos)) False

    , testCase "BsContinue inside do-while loop emits CpsGoto to branch PC" $ do
        let contStmt = at 2 BsContinue
            doStmt   = at 1 (BsDo (DoStmt (Just (DoWhile (ExBool True))) [contStmt] Nothing))
            g        = compile noEnv [doStmt]
            nodes    = cgNodes g
            gotos    = [ n | n@CpsGoto {} <- nodes ]
        assertBool "expected CpsGoto for BsContinue in do loop" (not (null gotos))
        case gotos of
          [CpsGoto { goTarget = tgt }] ->
            assertBool ("expected CpsBranch at header PC " <> show tgt)
                       (case drop tgt nodes of { (CpsBranch {} : _) -> True; _ -> False })
          _ -> assertBool ("unexpected goto count " <> show (length gotos)) False
    ]

  -- ------------------------------------------------------------------
  -- Gap 3: exprArgs arg-boundary fix (Plan 112 / 115 item 3B)

  , testGroup "Gap 3 – exprArgs / retokenize upgrade"

    [ testCase "exprArgs: single-token arg becomes ExLvalue" $ do
        let stmt = at 1 (BsCall (ExCall { callee = lv1 "open", callArgs = [[tok "w_test"]] }))
            g    = compile noEnv [stmt]
            sus  = [ n | n@CpsSuspend {} <- cgNodes g ]
        case sus of
          [s] -> suArgs s @?= [ExLvalue (lv1 "w_test")]
          _   -> assertBool "expected one CpsSuspend" False

    , testCase "exprArgs: multi-token binary a + 1 → ExBinOp BopAdd (Plan 115 item 3B)" $ do
        let stmt = at 1 (BsCall (ExCall { callee = lv1 "open", callArgs = [[tok "a", tok "+", tok "1"]] }))
            g    = compile noEnv [stmt]
            sus  = [ n | n@CpsSuspend {} <- cgNodes g ]
        case sus of
          [s] -> do
            length (suArgs s) @?= 1
            case suArgs s of
              [ExBinOp { op = BopAdd }] -> pure ()
              args -> assertBool ("expected [ExBinOp BopAdd], got: " <> show args) False
          _ -> assertBool "expected one CpsSuspend" False

    , testCase "exprArgs: 2-arg call with multi-token first arg gives 2 results" $ do
        let stmt = at 1 (BsCall (ExCall
              { callee   = lv1 "open"
              , callArgs = [[tok "a", tok "+", tok "1"], [tok "b"]]
              }))
            g   = compile noEnv [stmt]
            sus = [ n | n@CpsSuspend {} <- cgNodes g ]
        case sus of
          [s] -> length (suArgs s) @?= 2
          _   -> assertBool "expected one CpsSuspend" False

    , testCase "parseArgList: quoted string → ExStr" $ do
        let stmt = at 1 (BsCall (ExCall { callee = lv1 "open", callArgs = [[tok "\"hello\""]] }))
            g    = compile noEnv [stmt]
            sus  = [ n | n@CpsSuspend {} <- cgNodes g ]
        case sus of
          [s] -> suArgs s @?= [ExStr "hello"]
          _   -> assertBool "expected one CpsSuspend" False

    , testCase "parseArgList: bool literal true → ExBool True" $ do
        let stmt = at 1 (BsCall (ExCall { callee = lv1 "open", callArgs = [[tok "true"]] }))
            g    = compile noEnv [stmt]
            sus  = [ n | n@CpsSuspend {} <- cgNodes g ]
        case sus of
          [s] -> suArgs s @?= [ExBool True]
          _   -> assertBool "expected one CpsSuspend" False

    , testCase "parseArgList: null → ExNull" $ do
        let stmt = at 1 (BsCall (ExCall { callee = lv1 "open", callArgs = [[tok "null"]] }))
            g    = compile noEnv [stmt]
            sus  = [ n | n@CpsSuspend {} <- cgNodes g ]
        case sus of
          [s] -> suArgs s @?= [ExNull]
          _   -> assertBool "expected one CpsSuspend" False

    , testCase "parseArgList: multi-token sub b - 2 → ExBinOp BopSub" $ do
        let stmt = at 1 (BsCall (ExCall { callee = lv1 "open", callArgs = [[tok "b", tok "-", tok "2"]] }))
            g    = compile noEnv [stmt]
            sus  = [ n | n@CpsSuspend {} <- cgNodes g ]
        case sus of
          [s] -> case suArgs s of
            [ExBinOp { op = BopSub }] -> pure ()
            args -> assertBool ("expected [ExBinOp BopSub], got: " <> show args) False
          _ -> assertBool "expected one CpsSuspend" False
    ]

  -- ------------------------------------------------------------------
  -- Item 2: CpsCallProc dispatch nodes (Plan 115)

  , testGroup "Item 2 – CpsCallProc dispatch"

    [ testCase "BsPbCall super::open → CpsCallProc super::open" $ do
        let stmt = at 5 (BsPbCall (PbCall "super" "open"))
            g    = compile noEnv [stmt]
            cps  = [ n | n@CpsCallProc {} <- cgNodes g ]
        assertBool "expected CpsCallProc" (not (null cps))
        case cps of
          (n:_) -> cpCallee n @?= "super::open"
          []    -> pure ()

    , testCase "BsPbCall produces empty cpArgs" $ do
        let stmt = at 5 (BsPbCall (PbCall "super" "open"))
            g    = compile noEnv [stmt]
            cps  = [ n | n@CpsCallProc {} <- cgNodes g ]
        case cps of
          (n:_) -> cpArgs n @?= []
          []    -> assertBool "expected CpsCallProc" False

    , testCase "BsPbCall with arbitrary ancestor → CpsCallProc ancestor::event" $ do
        let stmt = at 1 (BsPbCall (PbCall "w_master" "ue_preopen"))
            g    = compile noEnv [stmt]
            cps  = [ n | n@CpsCallProc {} <- cgNodes g ]
        case cps of
          (n:_) -> cpCallee n @?= "w_master::ue_preopen"
          []    -> assertBool "expected CpsCallProc" False

    , testCase "TriggerEvent(\"ie_retrieve\") → CpsCallProc triggerevent [ExStr]" $ do
        let stmt = at 10 (BsCall (ExCall
              { callee   = lv1 "TriggerEvent"
              , callArgs = [[tok "\"ie_retrieve\""]]
              }))
            g    = compile noEnv [stmt]
            cps  = [ n | n@CpsCallProc {} <- cgNodes g ]
        assertBool "expected CpsCallProc for TriggerEvent" (not (null cps))
        case cps of
          (n:_) -> do
            cpCallee n @?= "triggerevent"
            cpArgs  n @?= [ExStr "ie_retrieve"]
          [] -> pure ()

    , testCase "this.TriggerEvent(\"ev\") also → CpsCallProc triggerevent" $ do
        let stmt = at 10 (BsCall (ExCall
              { callee   = lv2 "this" "TriggerEvent"
              , callArgs = [[tok "\"ev\""]]
              }))
            g    = compile noEnv [stmt]
            cps  = [ n | n@CpsCallProc {} <- cgNodes g ]
        assertBool "expected CpsCallProc for this.TriggerEvent" (not (null cps))
        case cps of
          (n:_) -> cpCallee n @?= "triggerevent"
          []    -> pure ()

    , testCase "TriggerEvent does not produce CpsSuspend or CpsCall" $ do
        let stmt = at 10 (BsCall (ExCall
              { callee   = lv1 "triggerevent"
              , callArgs = [[tok "\"ev\""]]
              }))
            g    = compile noEnv [stmt]
        [ n | n@CpsSuspend {} <- cgNodes g ] @?= []
        [ n | n@CpsCall    {} <- cgNodes g ] @?= []

    , testCase "BsRaw still falls through to no-op (no CpsCallProc)" $ do
        let stmt = at 1 (BsRaw "call super::open")
            g    = compile noEnv [stmt]
            cps  = [ n | n@CpsCallProc {} <- cgNodes g ]
        cps @?= []
    ]

  -- ------------------------------------------------------------------
  -- Item 1 – fn_retrievechild compile (Plan 117)

  , testGroup "Item 1 – fn_retrievechild suspend"

    [ testCase "fn_retrievechild compiles to CpsSuspend retrieve:child_kodperiod:adw" $ do
        let stmt = at 3 (BsCall (ExCall
              { callee   = lv1 "fn_retrievechild"
              , callArgs = [[tok "adw"], [tok "\"kodperiod\""], [tok "gs_kodxrisi"]]
              }))
            g   = compile noEnv [stmt]
            sus = [ n | n@CpsSuspend {} <- cgNodes g ]
        case sus of
          [s] -> suEffect s @?= "retrieve:child_kodperiod:adw"
          _   -> assertBool "expected one CpsSuspend" False

    , testCase "fn_retrievechild CpsSuspend carries only the 3rd arg (SQL param)" $ do
        let stmt = at 3 (BsCall (ExCall
              { callee   = lv1 "fn_retrievechild"
              , callArgs = [[tok "adw"], [tok "\"kodperiod\""], [tok "gs_kodxrisi"]]
              }))
            g   = compile noEnv [stmt]
            sus = [ n | n@CpsSuspend {} <- cgNodes g ]
        case sus of
          [s] -> length (suArgs s) @?= 1
          _   -> assertBool "expected one CpsSuspend" False
    ]

  -- ------------------------------------------------------------------
  -- Item 3 – user-fn dispatch (Plan 117)

  , testGroup "Item 3 – user-fn dispatch"

    [ testCase "single-segment user fn in registry → CpsCallProc" $ do
        let stmt = at 1 (BsCall (ExCall { callee = lv1 "wf_init", callArgs = [] }))
            g    = compileWith noEnv ["wf_init"] [stmt]
            cps  = [ n | n@CpsCallProc {} <- cgNodes g ]
        assertBool "expected CpsCallProc for user fn" (not (null cps))
        case cps of
          (n:_) -> cpCallee n @?= "wf_init"
          []    -> pure ()

    , testCase "single-segment call NOT in registry → CpsCall (unchanged)" $ do
        let stmt = at 1 (BsCall (ExCall { callee = lv1 "messagebox", callArgs = [] }))
            g    = compileWith noEnv ["wf_init"] [stmt]   -- messagebox not in set
            cps  = [ n | n@CpsCallProc {} <- cgNodes g ]
            calls = [ n | n@CpsCall {} <- cgNodes g ]
        cps   @?= []
        assertBool "expected CpsCall for non-user-fn" (not (null calls))
    ]

  , testGroup "body locals"
    [ testCase "body-declared BsLocalVar shadows instance type for classify" $ do
        -- steInstance has dw : integer (not a DW type).
        -- Body declares `datawindow dw` then calls `dw.retrieve()`.
        -- Without collectBodyLocals, dw.retrieve() would be Pure.
        -- With it, the body-local dw : datawindow shadows → Suspend.
        let env = ScopedTypeEnv
              { steGlobal    = Map.empty
              , steInstance  = Map.singleton "dw" (PtPrimitive "integer")
              , steLocal     = Map.empty
              , steHierarchy = Map.empty
              }
            body =
              [ at 1 (BsLocalVar [] (PtPrimitive "datawindow") "dw" Nothing)
              , at 2 (BsCall (ExCall { callee = lv2 "dw" "retrieve", callArgs = [] }))
              ]
            g = compile env body
        assertBool "dw.retrieve() should be a suspension point" (not (null (cgSuspensionPoints g)))
    ]
  ]
