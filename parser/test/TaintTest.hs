module TaintTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt     (BodyStmt (..))
import PB.AST.Expr         (LvSegment (..), Lvalue (..))
import PB.AST.Located      (Located (..))
import PB.AST.SourceFile
import PB.Pipeline.Taint

import qualified Data.Set as Set
import qualified Data.Text as T
import Test.Tasty           (TestTree, testGroup)
import Test.Tasty.HUnit     (assertBool, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Helpers

at :: Int -> a -> Located a
at n x = Located n x

lv1 :: Text -> Lvalue
lv1 n = Lvalue [LvSegment n Nothing]

mkSf :: [FunctionBlock] -> [SubroutineBlock] -> [EventBlock] -> [OnBlock] -> SrFile
mkSf fns subs evs obs = SrFile
  { srHeaders = [], srForward = Nothing, srPrototypes = Nothing
  , srVariables = Nothing, srGlobalInstances = [], srTypeBlocks = []
  , srOnBlocks = obs, srEvents = evs, srFunctions = fns, srSubroutines = subs
  }

mkFn :: Text -> [Text] -> Text -> [Located BodyStmt] -> FunctionBlock
mkFn name params ret body = FunctionBlock
  { fbSig = FnSig [] ret name (T.intercalate ", " params) Nothing
  , fbBody = body
  }

mkSub :: Text -> [Text] -> [Located BodyStmt] -> SubroutineBlock
mkSub name params body = SubroutineBlock
  { sbSig = SubSig [] name (T.intercalate ", " params) Nothing
  , sbBody = body
  }

mkEv :: Text -> [Located BodyStmt] -> EventBlock
mkEv name body = EventBlock
  { evSig = EventSig name (name <> "()")
  , evOwner = Nothing
  , evBody = body
  }

mkOb :: Text -> Text -> [Located BodyStmt] -> OnBlock
mkOb owner event body = OnBlock
  { obQualName = owner <> "." <> event
  , obOwner = owner
  , obEvent = event
  , obBody = body
  }

defRow :: Text -> Text -> Text -> Text -> Int -> Int -> DefRow
defRow file obj proc var line stmtIdx = DefRow
  { drFile = file, drObject = obj, drProcName = proc
  , drVarName = var, drBlockId = "b0", drStmtIdx = stmtIdx
  , drLine = Just line, drKind = "assign"
  }

useRow :: Text -> Text -> Text -> Text -> Int -> Text -> UseRow
useRow file obj proc var line kind = UseRow
  { urFile = file, urObject = obj, urProcName = proc
  , urVarName = var, urBlockId = "b0", urStmtIdx = 0
  , urLine = Just line, urKind = kind
  }

edge :: Text -> Text -> Maybe Int -> Text -> Text -> Text -> Text -> Text -> Text -> InterprocEdge
edge co cp cl fo fp ek v cc fc = InterprocEdge
  { ieCallerObject = co, ieCallerProc = cp, ieCallerLine = cl
  , ieCalleeObject = fo, ieCalleeProc = fp, ieEdgeKind = ek
  , ieVarName = v, ieCallerContext = cc, ieCalleeContext = fc
  }

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "Taint"

  [ testGroup "classifySources"
    [ testCase "SELECT INTO single host var" $
        let sql = [SqlStmt "w.srf" "oa" "pA" (Just 5) "SELECT"
                     "SELECT col INTO :ls_result FROM tbl" True]
        in classifySources sql [] @?=
           [TaintSource "w.srf" "oa" "pA" "ls_result" "db_read" (Just 5)]

    , testCase "SELECT INTO multiple host vars" $
        let sql = [SqlStmt "w.srf" "oa" "pA" (Just 10) "SELECT"
                     "SELECT a, b INTO :ls_a, :ls_b FROM tbl" True]
            srcs = classifySources sql []
        in do
          length srcs @?= 2
          map tsVarName srcs @?= ["ls_a", "ls_b"]
          all (\s -> tsSourceType s == "db_read") srcs @?= True

    , testCase "SELECT without INTO produces no source" $
        let sql = [SqlStmt "w.srf" "oa" "pA" (Just 5) "SELECT"
                     "SELECT col FROM tbl" False]
        in classifySources sql [] @?= []

    , testCase "event handler param produces request_param source" $
        let procs = [ProcMeta "w.srf" "oa" "pA" "event" "string as_arg" "" (Just 3)]
        in classifySources [] procs @?=
           [TaintSource "w.srf" "oa" "pA" "as_arg" "request_param" (Just 3)]

    , testCase "non-event proc produces no source" $
        let procs = [ProcMeta "w.srf" "oa" "pA" "function" "string as_name" "string" Nothing]
        in classifySources [] procs @?= []
    ]

  , testGroup "classifySinks"
    [ testCase "INSERT with bind var" $
        let sql = [SqlStmt "w.srf" "oa" "pA" (Just 15) "INSERT"
                     "INSERT INTO tbl (col) VALUES (:ls_val)" False]
        in classifySinks sql @?=
           [TaintSink "w.srf" "oa" "pA" "ls_val" "db_write" "high" (Just 15)]

    , testCase "UPDATE with two bind vars" $
        let sql = [SqlStmt "w.srf" "oa" "pA" (Just 20) "UPDATE"
                     "UPDATE tbl SET col = :ls_new WHERE id = :ls_id" False]
            sks = classifySinks sql
        in do
          length sks @?= 2
          map tskVarName sks @?= ["ls_new", "ls_id"]
          all (\s -> tskSinkType s == "db_write") sks @?= True

    , testCase "EXECUTE IMMEDIATE is critical" $
        let sql = [SqlStmt "w.srf" "oa" "pA" (Just 30) "EXECUTE"
                     "EXECUTE IMMEDIATE :ls_sql" False]
            sks = classifySinks sql
        in case sks of
             [sk] -> do
               tskSinkType sk @?= "exec_immediate"
               tskSeverity sk @?= "critical"
               tskVarName sk @?= "ls_sql"
             _ -> error ("expected 1 sink, got " <> show (length sks))

    , testCase "SELECT produces no sink" $
        let sql = [SqlStmt "w.srf" "oa" "pA" (Just 5) "SELECT"
                     "SELECT col INTO :ls_x FROM tbl" True]
        in classifySinks sql @?= []

    , testCase "INSERT without bind vars gets *exec placeholder" $
        let sql = [SqlStmt "w.srf" "oa" "pA" (Just 15) "INSERT"
                     "INSERT INTO tbl DEFAULT VALUES" False]
        in classifySinks sql @?=
           [TaintSink "w.srf" "oa" "pA" "*exec" "db_write" "high" (Just 15)]
    ]

  , testGroup "propagateTaint"
    [ testCase "intra-proc: tainted ls_a used on same line as ls_b defined" $
        let sources = [TaintSource "w.srf" "oa" "pA" "ls_a" "db_read" (Just 1)]
            defs = [defRow "w.srf" "oa" "pA" "ls_b" 5 0]
            uses = [useRow "w.srf" "oa" "pA" "ls_a" 5 "rhs"]
            (tainted, _) = propagateTaint sources defs uses []
        in do
          assertBool "ls_a is tainted" (("oa", "pA", "ls_a") `Set.member` tainted)
          assertBool "ls_b is tainted" (("oa", "pA", "ls_b") `Set.member` tainted)

    , testCase "arg edge: tainted caller var → callee param" $
        let sources = [TaintSource "w.srf" "oa" "pA" "x" "db_read" (Just 1)]
            e = edge "oa" "pA" Nothing "ob" "pB" "arg" "x" "x" "p1"
            (tainted, _) = propagateTaint sources [] [] [e]
        in assertBool "p1 in ob/pB is tainted"
             (("ob", "pB", "p1") `Set.member` tainted)

    , testCase "return edge: tainted var returned → caller lhs tainted" $
        let sources = [TaintSource "w.srf" "ob" "pB" "ls_val" "db_read" (Just 1)]
            retUse = useRow "w.srf" "ob" "pB" "ls_val" 10 "return"
            e = edge "oa" "pA" Nothing "ob" "pB" "return" "result" "result" "return"
            (tainted, _) = propagateTaint sources [] [retUse] [e]
        in assertBool "result in oa/pA is tainted"
             (("oa", "pA", "result") `Set.member` tainted)

    , testCase "global write edge: tainted global propagates to reader" $
        let sources = [TaintSource "w.srf" "oa" "pA" "g_val" "db_read" (Just 1)]
            e = edge "oa" "pA" Nothing "ob" "pB" "global_write" "g_val" "g_val" "g_val"
            (tainted, _) = propagateTaint sources [] [] [e]
        in assertBool "g_val in ob/pB is tainted"
             (("ob", "pB", "g_val") `Set.member` tainted)

    , testCase "no propagation without connection" $
        let sources = [TaintSource "w.srf" "oa" "pA" "ls_x" "db_read" (Just 1)]
            (tainted, _) = propagateTaint sources [] [] []
        in assertBool "unrelated var not tainted"
             (("ob", "pB", "ls_x") `Set.notMember` tainted)
    ]

  , testGroup "buildInterprocEdges"
    [ testCase "arg edge from resolved call" $
        let rc = [ResolvedCallRow "w.srf" "oa" "pA" "of_calc" "virtual"
                    (Just 10) (Just "ob") (Just "pB") "virtual" "high" Nothing]
            uses = [useRow "w.srf" "oa" "pA" "ls_x" 10 "rhs"]
            metas = [ProcMeta "w.srf" "ob" "pB" "function" "string as_arg" "" Nothing]
            edges = buildInterprocEdges rc [] uses Set.empty metas
        in case edges of
             [e] -> do
               ieEdgeKind e @?= "arg"
               ieCallerContext e @?= "ls_x"
               ieCalleeContext e @?= "as_arg"
             _ -> error ("expected 1 edge, got " <> show (length edges))

    , testCase "unresolved call produces no edge" $
        let rc = [ResolvedCallRow "w.srf" "oa" "pA" "foo" "unresolved"
                    (Just 10) Nothing Nothing "unresolved" "low" Nothing]
        in buildInterprocEdges rc [] [] Set.empty [] @?= []

    , testCase "builtin call with non-void return produces return edge" $
        let rc = [ResolvedCallRow "w.srf" "oa" "pA" "len" "builtin"
                    (Just 10) Nothing Nothing "builtin" "high" (Just "long")]
            defs = [defRow "w.srf" "oa" "pA" "li_len" 10 0]
            edges = buildInterprocEdges rc defs [] Set.empty []
        in case edges of
             [e] -> do
               ieEdgeKind e @?= "return"
               ieCalleeObject e @?= "__builtin__"
             _ -> error ("expected 1 edge, got " <> show (length edges))
    ]

  , testGroup "taintAnalysis"
    [ testCase "SELECT INTO to INSERT in same proc → one path" $
        let sf = mkSf [mkFn "of_test" [] "long"
                        [ at 5 (BsRaw "SELECT col INTO :ls_val FROM tbl")
                        , at 10 (BsRaw "INSERT INTO other (col) VALUES (:ls_val)")
                        ]] [] [] []
            result = taintAnalysis [] [] [] Set.empty "w.srf" sf
        in case trPaths result of
             [p] -> do
               tpSeverity p @?= "high"
               tpCategory p @?= "sql_injection"
             ps -> error ("expected 1 path, got " <> show (length ps))

    , testCase "no sources or sinks → empty result" $
        let sf = mkSf [mkFn "of_clean" [] "" []] [] [] []
            result = taintAnalysis [] [] [] Set.empty "w.srf" sf
        in do
          trSources result @?= []
          trSinks result @?= []
          trPaths result @?= []

    , testCase "SELECT INTO to INSERT in same proc → verify path details" $
        let sf = mkSf [mkFn "of_test2" [] "long"
                        [ at 5 (BsRaw "SELECT col INTO :ls_val FROM tbl")
                        , at 10 (BsRaw "INSERT INTO other (col) VALUES (:ls_val)")
                        ]] [] [] []
            result = taintAnalysis [] [] [] Set.empty "w.srf" sf
            p = case trPaths result of { (x:_) -> x; [] -> error "no paths" }
        in do
          tsVarName (tpSource p) @?= "ls_val"
          tskVarName (tpSink p) @?= "ls_val"
          tpSeverity p @?= "high"
          tpCategory p @?= "sql_injection"
    ]
  ]
