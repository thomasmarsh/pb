module CpsCompileTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr         (BinOp (..), Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Located      (Located (..))
import PB.AST.Type         (PbType (..))
import PB.Pipeline.CpsCompile
import PB.Pipeline.TypeEnv (TypeEnv (..))

import qualified Data.Map.Strict as Map
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

-- dw.retrieve()  (2-segment ExCall)
retrieveCall :: Expr
retrieveCall =
  ExCall { callee = lv2 "dw" "retrieve", callArgs = [] }

-- open(w_test)
openCall :: Expr
openCall =
  ExCall { callee = lv1 "open", callArgs = [["w_test"]] }

-- messagebox("hi")
pureCall :: Expr
pureCall =
  ExCall { callee = lv1 "messagebox", callArgs = [["\"hi\""]] }

-- ---------------------------------------------------------------------------
-- Convenience env builders

emptyEnv :: TypeEnv
emptyEnv = TypeEnv { teVars = Map.empty, teUserTypes = Map.empty }

-- | Single var → user-defined type, no inheritance.
varEnv :: Text -> Text -> TypeEnv
varEnv v t = TypeEnv { teVars = Map.singleton v (PtUserDefined t), teUserTypes = Map.empty }

-- | Single var + inheritance chain.
varEnvInh :: [(Text, Text)] -> [(Text, Text)] -> TypeEnv
varEnvInh vars inh = TypeEnv
  { teVars      = Map.fromList [(v, PtUserDefined t) | (v, t) <- vars]
  , teUserTypes = Map.fromList inh
  }

dwEnv :: TypeEnv
dwEnv = varEnv "dw" "datawindow"

transEnv :: TypeEnv
transEnv = varEnv "sqlca" "transaction"

noEnv :: TypeEnv
noEnv = emptyEnv

-- ---------------------------------------------------------------------------

tests :: TestTree
tests = testGroup "CpsCompile"

  -- ------------------------------------------------------------------
  -- Existing structural tests (updated to new compileProcedure signature)

  [ testCase "empty body → single CpsReturn at entry 0" $ do
      let g = compileProcedure noEnv []
      cgEntry g @?= 0
      length (cgNodes g) @?= 1
      case cgNodes g of
        [CpsReturn Nothing] -> pure ()
        ns                  -> assertBool ("expected [CpsReturn Nothing], got: " <> show ns) False

  , testCase "single BsAssign → assign node + return, entry ≠ 0" $ do
      let stmt = at 10 (BsAssign (lv1 "x") (ExInt "1"))
          g    = compileProcedure noEnv [stmt]
      length (cgNodes g) @?= 2
      assertBool "entry should be > 0" (cgEntry g > 0)
      case cgNodes g of
        [CpsReturn {}, CpsAssign { anVar = "x" }] -> pure ()
        ns -> assertBool ("unexpected nodes: " <> show ns) False

  , testCase "BsCall retrieve with DataWindow type → CpsSuspend retrieve:dw" $ do
      let stmt = at 5 (BsCall retrieveCall)
          g    = compileProcedure dwEnv [stmt]
      let suNodes = [ n | n@CpsSuspend {} <- cgNodes g ]
      assertBool "expected at least one CpsSuspend" (not (null suNodes))
      case suNodes of
        (s:_) -> suEffect s @?= "retrieve:dw"
        _     -> pure ()

  , testCase "BsCall retrieve with DataWindow type → listed in suspensionPoints" $ do
      let stmt = at 5 (BsCall retrieveCall)
          g    = compileProcedure dwEnv [stmt]
      assertBool "suspensionPoints should be non-empty" (not (null (cgSuspensionPoints g)))

  , testCase "BsCall open → CpsSuspend with effect open" $ do
      let stmt = at 7 (BsCall openCall)
          g    = compileProcedure noEnv [stmt]
      let suNodes = [ n | n@CpsSuspend {} <- cgNodes g ]
      assertBool "expected CpsSuspend" (not (null suNodes))
      case suNodes of
        (s:_) -> suEffect s @?= "open"
        _     -> pure ()

  , testCase "pure BsCall → CpsCall (not suspend)" $ do
      let stmt = at 3 (BsCall pureCall)
          g    = compileProcedure noEnv [stmt]
      let suNodes = [ n | n@CpsSuspend {} <- cgNodes g ]
      let caNodes = [ n | n@CpsCall {} <- cgNodes g ]
      suNodes @?= []
      assertBool "expected CpsCall" (not (null caNodes))

  , testCase "BsIf → CpsBranch node" $ do
      let thenS = [at 2 (BsAssign (lv1 "x") (ExInt "1"))]
          stmt  = at 1 (BsIf (IfStmt (ExBool True) thenS [] Nothing))
          g     = compileProcedure noEnv [stmt]
      let brNodes = [ n | n@CpsBranch {} <- cgNodes g ]
      assertBool "expected CpsBranch" (not (null brNodes))

  , testCase "BsAssign on line 42 → 42 appears in sourceMap" $ do
      let stmt = at 42 (BsAssign (lv1 "x") (ExInt "1"))
          g    = compileProcedure noEnv [stmt]
      let lines_ = map snd (cgSourceMap g)
      assertBool "line 42 should be in sourceMap" (42 `elem` lines_)

  -- ------------------------------------------------------------------
  -- Type-guided classification

  , testGroup "type-guided classification"

    [ testCase "dw.retrieve() with DataWindow type → Suspend" $
        classifyExpr dwEnv
          (ExCall { callee = lv2 "dw" "retrieve", callArgs = [] })
          @?= Suspend

    , testCase "dw.retrieve() without type info → Pure (conservative)" $
        classifyExpr noEnv
          (ExCall { callee = lv2 "dw" "retrieve", callArgs = [] })
          @?= Pure

    , testCase "unknown_var.retrieve() without type info → Pure" $
        classifyExpr noEnv
          (ExCall { callee = lv2 "unknown_var" "retrieve", callArgs = [] })
          @?= Pure

    , testCase "dw.update() with DataWindow type → Suspend" $
        classifyExpr dwEnv
          (ExCall { callee = lv2 "dw" "update", callArgs = [] })
          @?= Suspend

    , testCase "dw.delete() with DataWindow type → Suspend" $
        classifyExpr dwEnv
          (ExCall { callee = lv2 "dw" "delete", callArgs = [] })
          @?= Suspend

    , testCase "dw.reset() with DataWindow type → Suspend" $
        classifyExpr dwEnv
          (ExCall { callee = lv2 "dw" "reset", callArgs = [] })
          @?= Suspend

    , testCase "dw.settransobject() with DataWindow type → Pure (setup only)" $
        classifyExpr dwEnv
          (ExCall { callee = lv2 "dw" "settransobject", callArgs = [] })
          @?= Pure

    , testCase "sqlca.commit() with Transaction type → Suspend" $
        classifyExpr transEnv
          (ExCall { callee = lv2 "sqlca" "commit", callArgs = [] })
          @?= Suspend

    , testCase "sqlca.rollback() with Transaction type → Suspend" $
        classifyExpr transEnv
          (ExCall { callee = lv2 "sqlca" "rollback", callArgs = [] })
          @?= Suspend

    , testCase "sqlca.connect() with Transaction type → Suspend" $
        classifyExpr transEnv
          (ExCall { callee = lv2 "sqlca" "connect", callArgs = [] })
          @?= Suspend

    , testCase "sqlca.disconnect() with Transaction type → Suspend" $
        classifyExpr transEnv
          (ExCall { callee = lv2 "sqlca" "disconnect", callArgs = [] })
          @?= Suspend

    , testCase "fn_retrievechild() always Suspend (builtin)" $
        classifyExpr noEnv
          (ExCall { callee = lv1 "fn_retrievechild", callArgs = [] })
          @?= Suspend

    , testCase "open() always Suspend (builtin)" $
        classifyExpr noEnv
          (ExCall { callee = lv1 "open", callArgs = [["w_test"]] })
          @?= Suspend

    , testCase "opensheet() always Suspend (builtin)" $
        classifyExpr noEnv
          (ExCall { callee = lv1 "opensheet", callArgs = [] })
          @?= Suspend

    , testCase "close() always Suspend (builtin)" $
        classifyExpr noEnv
          (ExCall { callee = lv1 "close", callArgs = [] })
          @?= Suspend

    , testCase "datastore receiver treated same as datawindow → Suspend" $
        classifyExpr (varEnv "ds" "datastore")
          (ExCall { callee = lv2 "ds" "retrieve", callArgs = [] })
          @?= Suspend

    , testCase "effect name: open() → open" $
        effectName (ExCall { callee = lv1 "open", callArgs = [] })
          @?= "open"

    , testCase "effect name: opensheet() → open" $
        effectName (ExCall { callee = lv1 "opensheet", callArgs = [] })
          @?= "open"

    , testCase "effect name: close() → close" $
        effectName (ExCall { callee = lv1 "close", callArgs = [] })
          @?= "close"

    , testCase "effect name: dw.retrieve() → retrieve:dw" $
        effectName (ExCall { callee = lv2 "dw" "retrieve", callArgs = [] })
          @?= "retrieve:dw"

    , testCase "effect name: fn_retrievechild() → executeSql" $
        effectName (ExCall { callee = lv1 "fn_retrievechild", callArgs = [] })
          @?= "executeSql"

    , testCase "InheritGraph: user type inheriting datawindow → Suspend" $
        classifyExpr (varEnvInh [("ids_data", "n_cst_ds")] [("n_cst_ds", "datastore")])
          (ExCall { callee = lv2 "ids_data" "retrieve", callArgs = [] })
          @?= Suspend

    , testCase "InheritGraph: user type NOT inheriting DW → Pure" $
        classifyExpr (varEnvInh [("myobj", "n_some_struct")] [("n_some_struct", "structure")])
          (ExCall { callee = lv2 "myobj" "retrieve", callArgs = [] })
          @?= Pure
    ]

  , testGroup "cross-file InheritGraph"
    [ testCase "two-step chain: my_ds → n_cst_ds → datastore → Suspend" $
        classifyExpr (varEnvInh [("my_ds", "n_cst_ds")]
                                [("n_cst_ds", "datastore"), ("datastore", "datawindow")])
          (ExCall { callee = lv2 "my_ds" "retrieve", callArgs = [] })
          @?= Suspend

    , testCase "cycle guard: chain with loop does not hang" $
        classifyExpr (varEnvInh [("x", "a")] [("a", "b"), ("b", "a")])
          (ExCall { callee = lv2 "x" "retrieve", callArgs = [] })
          @?= Pure

    , testCase "deep chain (5 levels): still resolves to datawindow → Suspend" $
        classifyExpr (varEnvInh [("deep", "l5")]
                                [ ("l5", "l4"), ("l4", "l3"), ("l3", "l2")
                                , ("l2", "l1"), ("l1", "datawindow") ])
          (ExCall { callee = lv2 "deep" "retrieve", callArgs = [] })
          @?= Suspend

    , testCase "unknown type not in chain → Pure" $
        classifyExpr (varEnvInh [("mystery", "unknown_type")] [("n_cst_ds", "datastore")])
          (ExCall { callee = lv2 "mystery" "retrieve", callArgs = [] })
          @?= Pure
    ]

  , testGroup "ExMethodCall classification"
    [ testCase "ExMethodCall with ExLvalue receiver (datawindow) → Suspend" $
        classifyExpr (varEnv "dw" "datawindow")
          (ExMethodCall (ExLvalue (lv1 "dw")) "retrieve" [])
          @?= Suspend

    , testCase "ExMethodCall with ExLvalue receiver (transaction) → Suspend" $
        classifyExpr (varEnv "sqlca" "transaction")
          (ExMethodCall (ExLvalue (lv1 "sqlca")) "commit" [])
          @?= Suspend

    , testCase "ExMethodCall with ExCall receiver (single-segment callee in env) → Suspend" $
        classifyExpr (varEnv "get_dw" "datawindow")
          (ExMethodCall (ExCall (lv1 "get_dw") []) "retrieve" [])
          @?= Suspend

    , testCase "ExMethodCall with ExCall receiver (multi-segment callee) → Pure" $
        classifyExpr (varEnv "ns_func.get_dw" "datawindow")
          (ExMethodCall (ExCall (lv2 "ns_func" "get_dw") []) "retrieve" [])
          @?= Pure

    , testCase "ExMethodCall settransobject on datastore → Pure (setup only)" $
        classifyExpr (varEnv "ids" "datastore")
          (ExMethodCall (ExLvalue (lv1 "ids")) "settransobject" [])
          @?= Pure

    , testCase "ExMethodCall rowscopy on datastore → Suspend" $
        classifyExpr (varEnv "ids" "datastore")
          (ExMethodCall (ExLvalue (lv1 "ids")) "rowscopy" [])
          @?= Suspend

    , testCase "ExMethodCall describe on datawindow → Pure (read-only)" $
        classifyExpr (varEnv "dw" "datawindow")
          (ExMethodCall (ExLvalue (lv1 "dw")) "describe" [])
          @?= Pure
    ]

  -- ------------------------------------------------------------------
  -- Gap 1: BsAugAssign / BsInc / BsDec (Plan 112)

  , testGroup "Gap 1 – augmented assignment"

    [ testCase "BsAugAssign add emits CpsAssign with ExBinOp BopAdd" $ do
        let stmt = at 5 (BsAugAssign ["x"] AugAdd ["y"])
            g    = compileProcedure noEnv [stmt]
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
        let stmt = at 5 (BsAugAssign ["x"] AugSub ["y"])
            g    = compileProcedure noEnv [stmt]
            assignNodes = [ n | n@CpsAssign {} <- cgNodes g ]
        assertBool "expected CpsAssign for BsAugAssign sub" (not (null assignNodes))
        case assignNodes of
          (n:_) -> case anRhs n of
            ExBinOp { op = BopSub } -> pure ()
            e -> assertBool ("expected ExBinOp BopSub, got: " <> show e) False
          [] -> assertBool "no CpsAssign emitted" False

    , testCase "BsInc emits CpsAssign with ExBinOp BopAdd ExInt 1" $ do
        let stmt = at 3 (BsInc ["i"])
            g    = compileProcedure noEnv [stmt]
            assignNodes = [ n | n@CpsAssign {} <- cgNodes g ]
        assertBool "expected CpsAssign for BsInc" (not (null assignNodes))
        case assignNodes of
          (n:_) -> do
            anVar n @?= "i"
            anRhs n @?= ExBinOp { lhs = ExLvalue (lv1 "i"), op = BopAdd, rhs = ExInt "1" }
          [] -> assertBool "no CpsAssign emitted" False

    , testCase "BsDec emits CpsAssign with ExBinOp BopSub ExInt 1" $ do
        let stmt = at 3 (BsDec ["i"])
            g    = compileProcedure noEnv [stmt]
            assignNodes = [ n | n@CpsAssign {} <- cgNodes g ]
        assertBool "expected CpsAssign for BsDec" (not (null assignNodes))
        case assignNodes of
          (n:_) -> do
            anVar n @?= "i"
            anRhs n @?= ExBinOp { lhs = ExLvalue (lv1 "i"), op = BopSub, rhs = ExInt "1" }
          [] -> assertBool "no CpsAssign emitted" False

    , testCase "BsDestroy emits CpsAssign with ExNull (Plan 115 item 1)" $ do
        let stmt = at 4 (BsDestroy (lv1 "obj"))
            g    = compileProcedure noEnv [stmt]
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
            g    = compileProcedure noEnv [stmt]
            gotos = [ n | n@CpsGoto {} <- cgNodes g ]
        gotos @?= []

    , testCase "BsExit inside for loop emits CpsGoto to exit PC" $ do
        let exitStmt = at 2 BsExit
            forStmt  = at 1 (BsFor (ForStmt (lv1 "i") (ExInt "1") (ExInt "10") Nothing [exitStmt]))
            g        = compileProcedure noEnv [forStmt]
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
            g        = compileProcedure noEnv [forStmt]
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
            g        = compileProcedure noEnv [doStmt]
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
        let stmt = at 1 (BsCall (ExCall { callee = lv1 "open", callArgs = [["w_test"]] }))
            g    = compileProcedure noEnv [stmt]
            sus  = [ n | n@CpsSuspend {} <- cgNodes g ]
        case sus of
          [s] -> suArgs s @?= [ExLvalue (lv1 "w_test")]
          _   -> assertBool "expected one CpsSuspend" False

    , testCase "exprArgs: multi-token binary a + 1 → ExBinOp BopAdd (Plan 115 item 3B)" $ do
        let stmt = at 1 (BsCall (ExCall { callee = lv1 "open", callArgs = [["a", "+", "1"]] }))
            g    = compileProcedure noEnv [stmt]
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
              , callArgs = [["a", "+", "1"], ["b"]]
              }))
            g   = compileProcedure noEnv [stmt]
            sus = [ n | n@CpsSuspend {} <- cgNodes g ]
        case sus of
          [s] -> length (suArgs s) @?= 2
          _   -> assertBool "expected one CpsSuspend" False

    , testCase "parseArgList: quoted string → ExStr" $ do
        let stmt = at 1 (BsCall (ExCall { callee = lv1 "open", callArgs = [["\"hello\""]] }))
            g    = compileProcedure noEnv [stmt]
            sus  = [ n | n@CpsSuspend {} <- cgNodes g ]
        case sus of
          [s] -> suArgs s @?= [ExStr "hello"]
          _   -> assertBool "expected one CpsSuspend" False

    , testCase "parseArgList: bool literal true → ExBool True" $ do
        let stmt = at 1 (BsCall (ExCall { callee = lv1 "open", callArgs = [["true"]] }))
            g    = compileProcedure noEnv [stmt]
            sus  = [ n | n@CpsSuspend {} <- cgNodes g ]
        case sus of
          [s] -> suArgs s @?= [ExBool True]
          _   -> assertBool "expected one CpsSuspend" False

    , testCase "parseArgList: null → ExNull" $ do
        let stmt = at 1 (BsCall (ExCall { callee = lv1 "open", callArgs = [["null"]] }))
            g    = compileProcedure noEnv [stmt]
            sus  = [ n | n@CpsSuspend {} <- cgNodes g ]
        case sus of
          [s] -> suArgs s @?= [ExNull]
          _   -> assertBool "expected one CpsSuspend" False

    , testCase "parseArgList: multi-token sub b - 2 → ExBinOp BopSub" $ do
        let stmt = at 1 (BsCall (ExCall { callee = lv1 "open", callArgs = [["b", "-", "2"]] }))
            g    = compileProcedure noEnv [stmt]
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
            g    = compileProcedure noEnv [stmt]
            cps  = [ n | n@CpsCallProc {} <- cgNodes g ]
        assertBool "expected CpsCallProc" (not (null cps))
        case cps of
          (n:_) -> cpCallee n @?= "super::open"
          []    -> pure ()

    , testCase "BsPbCall produces empty cpArgs" $ do
        let stmt = at 5 (BsPbCall (PbCall "super" "open"))
            g    = compileProcedure noEnv [stmt]
            cps  = [ n | n@CpsCallProc {} <- cgNodes g ]
        case cps of
          (n:_) -> cpArgs n @?= []
          []    -> assertBool "expected CpsCallProc" False

    , testCase "BsPbCall with arbitrary ancestor → CpsCallProc ancestor::event" $ do
        let stmt = at 1 (BsPbCall (PbCall "w_master" "ue_preopen"))
            g    = compileProcedure noEnv [stmt]
            cps  = [ n | n@CpsCallProc {} <- cgNodes g ]
        case cps of
          (n:_) -> cpCallee n @?= "w_master::ue_preopen"
          []    -> assertBool "expected CpsCallProc" False

    , testCase "TriggerEvent(\"ie_retrieve\") → CpsCallProc triggerevent [ExStr]" $ do
        let stmt = at 10 (BsCall (ExCall
              { callee   = lv1 "TriggerEvent"
              , callArgs = [["\"ie_retrieve\""]]
              }))
            g    = compileProcedure noEnv [stmt]
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
              , callArgs = [["\"ev\""]]
              }))
            g    = compileProcedure noEnv [stmt]
            cps  = [ n | n@CpsCallProc {} <- cgNodes g ]
        assertBool "expected CpsCallProc for this.TriggerEvent" (not (null cps))
        case cps of
          (n:_) -> cpCallee n @?= "triggerevent"
          []    -> pure ()

    , testCase "TriggerEvent does not produce CpsSuspend or CpsCall" $ do
        let stmt = at 10 (BsCall (ExCall
              { callee   = lv1 "triggerevent"
              , callArgs = [["\"ev\""]]
              }))
            g    = compileProcedure noEnv [stmt]
        [ n | n@CpsSuspend {} <- cgNodes g ] @?= []
        [ n | n@CpsCall    {} <- cgNodes g ] @?= []

    , testCase "BsRaw still falls through to no-op (no CpsCallProc)" $ do
        let stmt = at 1 (BsRaw "call super::open")
            g    = compileProcedure noEnv [stmt]
            cps  = [ n | n@CpsCallProc {} <- cgNodes g ]
        cps @?= []
    ]
  ]
