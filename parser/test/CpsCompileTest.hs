module CpsCompileTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr         (Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Located      (Located (..))
import PB.Pipeline.CpsCompile

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

dwEnv :: TypeEnv
dwEnv = Map.singleton "dw" "datawindow"

transEnv :: TypeEnv
transEnv = Map.singleton "sqlca" "transaction"

noEnv :: TypeEnv
noEnv = Map.empty

noInh :: InheritGraph
noInh = Map.empty

-- ---------------------------------------------------------------------------

tests :: TestTree
tests = testGroup "CpsCompile"

  -- ------------------------------------------------------------------
  -- Existing structural tests (updated to new compileProcedure signature)

  [ testCase "empty body → single CpsReturn at entry 0" $ do
      let g = compileProcedure noEnv noInh []
      cgEntry g @?= 0
      length (cgNodes g) @?= 1
      case cgNodes g of
        [CpsReturn Nothing] -> pure ()
        ns                  -> assertBool ("expected [CpsReturn Nothing], got: " <> show ns) False

  , testCase "single BsAssign → assign node + return, entry ≠ 0" $ do
      let stmt = at 10 (BsAssign (lv1 "x") (ExInt "1"))
          g    = compileProcedure noEnv noInh [stmt]
      length (cgNodes g) @?= 2
      assertBool "entry should be > 0" (cgEntry g > 0)
      case cgNodes g of
        [CpsReturn {}, CpsAssign { anVar = "x" }] -> pure ()
        ns -> assertBool ("unexpected nodes: " <> show ns) False

  , testCase "BsCall retrieve with DataWindow type → CpsSuspend retrieve:dw" $ do
      let stmt = at 5 (BsCall retrieveCall)
          g    = compileProcedure dwEnv noInh [stmt]
      let suNodes = [ n | n@CpsSuspend {} <- cgNodes g ]
      assertBool "expected at least one CpsSuspend" (not (null suNodes))
      case suNodes of
        (s:_) -> suEffect s @?= "retrieve:dw"
        _     -> pure ()

  , testCase "BsCall retrieve with DataWindow type → listed in suspensionPoints" $ do
      let stmt = at 5 (BsCall retrieveCall)
          g    = compileProcedure dwEnv noInh [stmt]
      assertBool "suspensionPoints should be non-empty" (not (null (cgSuspensionPoints g)))

  , testCase "BsCall open → CpsSuspend with effect open" $ do
      let stmt = at 7 (BsCall openCall)
          g    = compileProcedure noEnv noInh [stmt]
      let suNodes = [ n | n@CpsSuspend {} <- cgNodes g ]
      assertBool "expected CpsSuspend" (not (null suNodes))
      case suNodes of
        (s:_) -> suEffect s @?= "open"
        _     -> pure ()

  , testCase "pure BsCall → CpsCall (not suspend)" $ do
      let stmt = at 3 (BsCall pureCall)
          g    = compileProcedure noEnv noInh [stmt]
      let suNodes = [ n | n@CpsSuspend {} <- cgNodes g ]
      let caNodes = [ n | n@CpsCall {} <- cgNodes g ]
      suNodes @?= []
      assertBool "expected CpsCall" (not (null caNodes))

  , testCase "BsIf → CpsBranch node" $ do
      let thenS = [at 2 (BsAssign (lv1 "x") (ExInt "1"))]
          stmt  = at 1 (BsIf (IfStmt (ExBool True) thenS [] Nothing))
          g     = compileProcedure noEnv noInh [stmt]
      let brNodes = [ n | n@CpsBranch {} <- cgNodes g ]
      assertBool "expected CpsBranch" (not (null brNodes))

  , testCase "BsAssign on line 42 → 42 appears in sourceMap" $ do
      let stmt = at 42 (BsAssign (lv1 "x") (ExInt "1"))
          g    = compileProcedure noEnv noInh [stmt]
      let lines_ = map snd (cgSourceMap g)
      assertBool "line 42 should be in sourceMap" (42 `elem` lines_)

  -- ------------------------------------------------------------------
  -- Type-guided classification

  , testGroup "type-guided classification"

    [ testCase "dw.retrieve() with DataWindow type → Suspend" $
        classifyExpr dwEnv noInh
          (ExCall { callee = lv2 "dw" "retrieve", callArgs = [] })
          @?= Suspend

    , testCase "dw.retrieve() without type info → Pure (conservative)" $
        classifyExpr noEnv noInh
          (ExCall { callee = lv2 "dw" "retrieve", callArgs = [] })
          @?= Pure

    , testCase "unknown_var.retrieve() without type info → Pure" $
        classifyExpr noEnv noInh
          (ExCall { callee = lv2 "unknown_var" "retrieve", callArgs = [] })
          @?= Pure

    , testCase "dw.update() with DataWindow type → Suspend" $
        classifyExpr dwEnv noInh
          (ExCall { callee = lv2 "dw" "update", callArgs = [] })
          @?= Suspend

    , testCase "dw.delete() with DataWindow type → Suspend" $
        classifyExpr dwEnv noInh
          (ExCall { callee = lv2 "dw" "delete", callArgs = [] })
          @?= Suspend

    , testCase "dw.reset() with DataWindow type → Suspend" $
        classifyExpr dwEnv noInh
          (ExCall { callee = lv2 "dw" "reset", callArgs = [] })
          @?= Suspend

    , testCase "dw.settransobject() with DataWindow type → Pure (setup only)" $
        classifyExpr dwEnv noInh
          (ExCall { callee = lv2 "dw" "settransobject", callArgs = [] })
          @?= Pure

    , testCase "sqlca.commit() with Transaction type → Suspend" $
        classifyExpr transEnv noInh
          (ExCall { callee = lv2 "sqlca" "commit", callArgs = [] })
          @?= Suspend

    , testCase "sqlca.rollback() with Transaction type → Suspend" $
        classifyExpr transEnv noInh
          (ExCall { callee = lv2 "sqlca" "rollback", callArgs = [] })
          @?= Suspend

    , testCase "sqlca.connect() with Transaction type → Suspend" $
        classifyExpr transEnv noInh
          (ExCall { callee = lv2 "sqlca" "connect", callArgs = [] })
          @?= Suspend

    , testCase "sqlca.disconnect() with Transaction type → Suspend" $
        classifyExpr transEnv noInh
          (ExCall { callee = lv2 "sqlca" "disconnect", callArgs = [] })
          @?= Suspend

    , testCase "fn_retrievechild() always Suspend (builtin)" $
        classifyExpr noEnv noInh
          (ExCall { callee = lv1 "fn_retrievechild", callArgs = [] })
          @?= Suspend

    , testCase "open() always Suspend (builtin)" $
        classifyExpr noEnv noInh
          (ExCall { callee = lv1 "open", callArgs = [["w_test"]] })
          @?= Suspend

    , testCase "opensheet() always Suspend (builtin)" $
        classifyExpr noEnv noInh
          (ExCall { callee = lv1 "opensheet", callArgs = [] })
          @?= Suspend

    , testCase "close() always Suspend (builtin)" $
        classifyExpr noEnv noInh
          (ExCall { callee = lv1 "close", callArgs = [] })
          @?= Suspend

    , testCase "datastore receiver treated same as datawindow → Suspend" $
        classifyExpr (Map.singleton "ds" "datastore") noInh
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
        let env = Map.singleton "ids_data" "n_cst_ds"
            inh = Map.singleton "n_cst_ds" "datastore"
        in classifyExpr env inh
             (ExCall { callee = lv2 "ids_data" "retrieve", callArgs = [] })
             @?= Suspend

    , testCase "InheritGraph: user type NOT inheriting DW → Pure" $
        let env = Map.singleton "myobj" "n_some_struct"
            inh = Map.singleton "n_some_struct" "structure"
        in classifyExpr env inh
             (ExCall { callee = lv2 "myobj" "retrieve", callArgs = [] })
             @?= Pure
    ]

  , testGroup "cross-file InheritGraph"
    [ testCase "two-step chain: my_ds → n_cst_ds → datastore → Suspend" $
        let env = Map.singleton "my_ds" "n_cst_ds"
            inh = Map.fromList [("n_cst_ds", "datastore"), ("datastore", "datawindow")]
        in classifyExpr env inh
             (ExCall { callee = lv2 "my_ds" "retrieve", callArgs = [] })
             @?= Suspend

    , testCase "cycle guard: chain with loop does not hang" $
        let env = Map.singleton "x" "a"
            inh = Map.fromList [("a", "b"), ("b", "a")]
        in classifyExpr env inh
             (ExCall { callee = lv2 "x" "retrieve", callArgs = [] })
             @?= Pure

    , testCase "deep chain (5 levels): still resolves to datawindow → Suspend" $
        let env = Map.singleton "deep" "l5"
            inh = Map.fromList [ ("l5", "l4"), ("l4", "l3")
                               , ("l3", "l2"), ("l2", "l1")
                               , ("l1", "datawindow") ]
        in classifyExpr env inh
             (ExCall { callee = lv2 "deep" "retrieve", callArgs = [] })
             @?= Suspend

    , testCase "unknown type not in chain → Pure" $
        let env = Map.singleton "mystery" "unknown_type"
            inh = Map.fromList [("n_cst_ds", "datastore")]
        in classifyExpr env inh
             (ExCall { callee = lv2 "mystery" "retrieve", callArgs = [] })
             @?= Pure
    ]

  , testGroup "ExMethodCall classification"
    [ testCase "ExMethodCall with ExLvalue receiver (datawindow) → Suspend" $
        let env = Map.singleton "dw" "datawindow"
        in classifyExpr env noInh
             (ExMethodCall (ExLvalue (lv1 "dw")) "retrieve" [])
             @?= Suspend

    , testCase "ExMethodCall with ExLvalue receiver (transaction) → Suspend" $
        let env = Map.singleton "sqlca" "transaction"
        in classifyExpr env noInh
             (ExMethodCall (ExLvalue (lv1 "sqlca")) "commit" [])
             @?= Suspend

    , testCase "ExMethodCall with ExCall receiver (single-segment callee in env) → Suspend" $
        let env = Map.singleton "get_dw" "datawindow"
        in classifyExpr env noInh
             (ExMethodCall (ExCall (lv1 "get_dw") []) "retrieve" [])
             @?= Suspend

    , testCase "ExMethodCall with ExCall receiver (multi-segment callee) → Pure" $
        let env = Map.singleton "ns_func.get_dw" "datawindow"
        in classifyExpr env noInh
             (ExMethodCall (ExCall (lv2 "ns_func" "get_dw") []) "retrieve" [])
             @?= Pure

    , testCase "ExMethodCall settransobject on datastore → Pure (setup only)" $
        let env = Map.singleton "ids" "datastore"
        in classifyExpr env noInh
             (ExMethodCall (ExLvalue (lv1 "ids")) "settransobject" [])
             @?= Pure

    , testCase "ExMethodCall rowscopy on datastore → Suspend" $
        let env = Map.singleton "ids" "datastore"
        in classifyExpr env noInh
             (ExMethodCall (ExLvalue (lv1 "ids")) "rowscopy" [])
             @?= Suspend

    , testCase "ExMethodCall describe on datawindow → Pure (read-only)" $
        let env = Map.singleton "dw" "datawindow"
        in classifyExpr env noInh
             (ExMethodCall (ExLvalue (lv1 "dw")) "describe" [])
             @?= Pure
    ]
  ]
