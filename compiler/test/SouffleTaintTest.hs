module SouffleTaintTest (tests) where

import PB.Prelude
import PB.Pipeline.Souffle
import PB.Analysis.Rules.Taint
import PB.Pipeline.DuckDb
import PB.Analysis.Taint qualified as Taint

import qualified Data.Text as T
import Data.List (sortOn)

import Database.DuckDB.Simple (Query (..), execute_, query_)
import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

-- ---------------------------------------------------------------------------
-- Helpers: insert synthetic taint data via literal SQL
-- ---------------------------------------------------------------------------

-- | Insert a def row: file, object, proc, var, line.
insDef :: DuckConn -> Text -> Text -> Text -> Text -> Int -> IO ()
insDef conn file obj proc var line =
  void $ execute_ conn
    (Query ("INSERT INTO proc_defs VALUES ('" <> file <> "','" <> obj <> "','" <> proc <> "','" <> var <> "','b0',0," <> T.pack (show line) <> ",'assign')") :: Query)

-- | Insert a use row: file, object, proc, var, line, kind.
insUse :: DuckConn -> Text -> Text -> Text -> Text -> Int -> Text -> IO ()
insUse conn file obj proc var line kind =
  void $ execute_ conn
    (Query ("INSERT INTO proc_uses VALUES ('" <> file <> "','" <> obj <> "','" <> proc <> "','" <> var <> "','b0',0," <> T.pack (show line) <> ",'" <> kind <> "')") :: Query)

-- | Insert an interproc edge.
insEdge :: DuckConn -> Text -> Text -> Text -> Text -> Text -> Text -> Text -> Text -> Text -> IO ()
insEdge conn co cp _cc fo fp ek v callerCtx calleeCtx =
  void $ execute_ conn
    (Query ("INSERT INTO interproc_edges VALUES ('" <> co <> "','" <> cp <> "',NULL,'" <> fo <> "','" <> fp <> "','" <> ek <> "','" <> v <> "','" <> callerCtx <> "','" <> calleeCtx <> "')") :: Query)

-- | Insert a taint source.
insSource :: DuckConn -> Text -> Text -> Text -> Text -> Text -> IO ()
insSource conn file obj proc var srcType =
  void $ execute_ conn
    (Query ("INSERT INTO taint_sources VALUES ('" <> file <> "','" <> obj <> "','" <> proc <> "','" <> var <> "','" <> srcType <> "',NULL)") :: Query)

-- | Insert a taint sink.
insSink :: DuckConn -> Text -> Text -> Text -> Text -> Text -> Text -> IO ()
insSink conn file obj proc var sinkType sev =
  void $ execute_ conn
    (Query ("INSERT INTO taint_sinks VALUES ('" <> file <> "','" <> obj <> "','" <> proc <> "','" <> var <> "','" <> sinkType <> "','" <> sev <> "',NULL)") :: Query)

-- | Run initSchema + initTaintEdbViews + taintRules, query confirmed.
runTaint :: DuckConn -> IO [(Text, Text)]
runTaint conn = do
  initSchema conn
  initTaintEdbViews conn
  runRuleSet conn taintRules
  query_ conn "SELECT s, t FROM taint_confirmed" :: IO [(Text, Text)]

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

tests :: TestTree
tests = testGroup "Souffle.Taint"

  [ testGroup "taintRules"
    [ testCase "two-node intra-proc chain: source A -> sink B via def-use" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          -- source: obj.proc_a.ls_x, sink: obj.proc_a.ls_b
          -- def: ls_b defined at line 10; use: ls_x used at line 10 (same line -> def edge)
          insDef  conn "f.srw" "obj" "proc_a" "ls_b" 10
          insUse  conn "f.srw" "obj" "proc_a" "ls_x" 10 "assign"
          insSource conn "f.srw" "obj" "proc_a" "ls_x" "db_read"
          insSink   conn "f.srw" "obj" "proc_a" "ls_b" "db_write" "high"
          confirmed <- runTaint conn
          let srcKey = "obj::proc_a::ls_x"
              snkKey = "obj::proc_a::ls_b"
          assertBool "source->sink confirmed" ((srcKey, snkKey) `elem` confirmed)

    , testCase "three-node chain: A -> B -> C, source=A sink=C -> confirmed" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          -- intra-proc edge in proc_a: ls_x used at line 10, ls_b defined at line 10
          insDef  conn "f.srw" "obj" "proc_a" "ls_b" 10
          insUse  conn "f.srw" "obj" "proc_a" "ls_x" 10 "assign"
          -- interproc arg edge: proc_a.ls_b passed as proc_b.ls_y
          insEdge conn "obj" "proc_a" "" "obj" "proc_b" "arg" "ls_b" "ls_b" "ls_y"
          -- intra-proc edge in proc_b: ls_y used at line 20, ls_c defined at line 20
          insDef  conn "f.srw" "obj" "proc_b" "ls_c" 20
          insUse  conn "f.srw" "obj" "proc_b" "ls_y" 20 "assign"
          insSource conn "f.srw" "obj" "proc_a" "ls_x" "db_read"
          insSink   conn "f.srw" "obj" "proc_b" "ls_c" "db_write" "high"
          confirmed <- runTaint conn
          let srcKey = "obj::proc_a::ls_x"
              snkKey = "obj::proc_b::ls_c"
          assertBool "A->B->C confirmed" ((srcKey, snkKey) `elem` confirmed)

    , testCase "arg edge: caller A passes tainted var to callee B -> confirmed" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          insSource conn "f.srw" "obj_a" "proc_x" "ls_arg" "db_read"
          insSink   conn "f.srw" "obj_b" "proc_y" "ls_param" "db_write" "high"
          insEdge   conn "obj_a" "proc_x" "" "obj_b" "proc_y" "arg" "ls_arg" "ls_arg" "ls_param"
          confirmed <- runTaint conn
          let srcKey = "obj_a::proc_x::ls_arg"
              snkKey = "obj_b::proc_y::ls_param"
          assertBool "arg edge confirmed" ((srcKey, snkKey) `elem` confirmed)

    , testCase "return edge: callee return-var tainted -> caller lhs tainted" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          insUse  conn "f.srw" "obj" "proc_y" "ls_ret" 5 "return"
          insDef  conn "f.srw" "obj" "proc_x" "ls_lhs" 5
          insSource conn "f.srw" "obj" "proc_y" "ls_ret" "db_read"
          insSink   conn "f.srw" "obj" "proc_x" "ls_lhs" "db_write" "high"
          insEdge   conn "obj" "proc_x" "" "obj" "proc_y" "return" "ls_ret" "ls_lhs" "return"
          confirmed <- runTaint conn
          let srcKey = "obj::proc_y::ls_ret"
              snkKey = "obj::proc_x::ls_lhs"
          assertBool "return edge confirmed" ((srcKey, snkKey) `elem` confirmed)

    , testCase "global write edge: writer A global -> reader B global -> confirmed" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          insSource conn "f.srw" "obj_w" "proc_w" "gv_shared" "db_read"
          insSink   conn "f.srw" "obj_r" "proc_r" "gv_shared" "db_write" "high"
          insEdge   conn "obj_w" "proc_w" "" "obj_r" "proc_r" "global_write" "gv_shared" "gv_shared" "gv_shared"
          confirmed <- runTaint conn
          let srcKey = "obj_w::proc_w::gv_shared"
              snkKey = "obj_r::proc_r::gv_shared"
          assertBool "global write confirmed" ((srcKey, snkKey) `elem` confirmed)

    , testCase "no-path: source and sink in disconnected components -> not confirmed" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          insSource conn "f.srw" "obj_a" "proc_a" "ls_x" "db_read"
          insSink   conn "f.srw" "obj_b" "proc_b" "ls_y" "db_write" "high"
          confirmed <- runTaint conn
          let srcKey = "obj_a::proc_a::ls_x"
              snkKey = "obj_b::proc_b::ls_y"
          assertBool "disconnected: not confirmed" ((srcKey, snkKey) `notElem` confirmed)

    , testCase "cycle termination: source in self-cycle via global_write -> terminates" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          insSource conn "f.srw" "obj" "proc_a" "ls_x" "db_read"
          insSink   conn "f.srw" "obj" "proc_b" "ls_y" "db_write" "high"
          insEdge   conn "obj" "proc_a" "" "obj" "proc_a" "global_write" "ls_x" "ls_x" "ls_x"
          insEdge   conn "obj" "proc_a" "" "obj" "proc_b" "global_write" "ls_x" "ls_x" "ls_y"
          confirmed <- runTaint conn
          let srcKey = "obj::proc_a::ls_x"
              snkKey = "obj::proc_b::ls_y"
          assertBool "reachable outside cycle" ((srcKey, snkKey) `elem` confirmed)

    , testCase "cyclic non-seed: A->B->C->B (cycle not through source) -> terminates" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          insSource conn "f.srw" "obj" "proc_a" "ls_x" "db_read"
          insSink   conn "f.srw" "obj" "proc_c" "ls_z" "db_write" "high"
          insEdge   conn "obj" "proc_a" "" "obj" "proc_b" "global_write" "ls_x" "ls_x" "ls_y"
          insEdge   conn "obj" "proc_b" "" "obj" "proc_c" "global_write" "ls_y" "ls_y" "ls_z"
          insEdge   conn "obj" "proc_c" "" "obj" "proc_b" "global_write" "ls_z" "ls_z" "ls_y"
          confirmed <- runTaint conn
          let srcKey = "obj::proc_a::ls_x"
              snkKey = "obj::proc_c::ls_z"
          assertBool "B<->C cycle terminates, C still reachable" ((srcKey, snkKey) `elem` confirmed)
    ]

  , testGroup "taintReaches"
    -- Coverage gap closed 2026-07-15: taint_reaches' seed was restricted to
    -- taint_source (perf fix, see PB.Analysis.Rules.Taint's own doc
    -- comment) -- materializeTaintAnnotations (DuckDb.hs) is its sole other
    -- consumer, and no existing test asserted on taint_reaches' own content
    -- directly (only on taint_confirmed/taint_step_kind, which don't
    -- exercise this relation at all). These two cases are exactly what a
    -- source-seed restriction could get wrong: a dead-end node (never a
    -- sink, must still be present -- narrowing this would silently change
    -- materializeTaintAnnotations' "tainted set") and a node reachable only
    -- from a non-source root (must be absent -- confirms the seed really
    -- is restricted, not silently reverted to unrestricted).
    [ testCase "dead-end node past no sink is still in taint_reaches (materializeTaintAnnotations needs it)" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          -- A -> B -> C chain, A is the only taint_source, C is NOT a
          -- taint_sink (no insSink call at all) -- a pure dead end.
          insEdge   conn "obj" "proc_a" "" "obj" "proc_b" "global_write" "ls_a" "ls_a" "ls_b"
          insEdge   conn "obj" "proc_b" "" "obj" "proc_c" "global_write" "ls_b" "ls_b" "ls_c"
          insSource conn "f.srw" "obj" "proc_a" "ls_a" "db_read"
          initTaintEdbViews conn
          runRuleSet conn taintRules
          reaches <- query_ conn "SELECT x, y FROM taint_reaches" :: IO [(Text, Text)]
          let srcKey = "obj::proc_a::ls_a"
              bKey   = "obj::proc_b::ls_b"
              cKey   = "obj::proc_c::ls_c"
          assertBool "source reaches intermediate B" ((srcKey, bKey) `elem` reaches)
          assertBool "source reaches dead-end C (no sink downstream)" ((srcKey, cKey) `elem` reaches)

    , testCase "node reachable only from a non-source root is absent from taint_reaches" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          -- X -> Y edge where X is NOT a taint_source at all -- under the
          -- source-seeded taint_reaches, X should never appear as a root.
          insEdge   conn "obj" "proc_x" "" "obj" "proc_y" "global_write" "ls_x" "ls_x" "ls_y"
          initTaintEdbViews conn
          runRuleSet conn taintRules
          reaches <- query_ conn "SELECT x, y FROM taint_reaches" :: IO [(Text, Text)]
          assertEqual "no taint_source declared -> taint_reaches is empty" [] reaches
    ]

  , testGroup "taintStepKind"
    [ testCase "linear 3-hop chain: source step, passthrough-kind steps, terminal sink step" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          -- A -(def)-> B -(arg)-> C -(global)-> D: 3 edges, source=A sink=D.
          insDef conn "f.srw" "obj" "proc_a" "ls_b" 10
          insUse conn "f.srw" "obj" "proc_a" "ls_a" 10 "assign"
          insEdge conn "obj" "proc_a" "" "obj" "proc_b" "arg" "ls_b" "ls_b" "ls_c"
          insEdge conn "obj" "proc_b" "" "obj" "proc_c" "global_write" "ls_c" "ls_c" "ls_d"
          insSource conn "f.srw" "obj" "proc_a" "ls_a" "db_read"
          insSink   conn "f.srw" "obj" "proc_c" "ls_d" "db_write" "high"
          rows <- runStepKind conn
          let srcKey = "obj::proc_a::ls_a"
              snkKey = "obj::proc_c::ls_d"
              path = [r | r@(s, t, _, _, _, _, _, _) <- rows, s == srcKey, t == snkKey]
              byOrd = sortOn (\(_, _, o, _, _, _, _, _) -> o) path
          assertEqual "4 labeled steps (source + 2 propagation + terminal sink)"
            4 (length byOrd)
          assertEqual "step 0 is source"
            [("0", "source", "taint source")] (stepKindTriples byOrd 0)
          assertEqual "step 3 is the terminal sink marker"
            [("3", "sink", "taint propagation via sink")] (stepKindTriples byOrd 3)

    , testCase "0-hop source-equals-sink pair: single source-sink step" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          insSource conn "f.srw" "obj" "proc_a" "ls_x" "db_read"
          insSink   conn "f.srw" "obj" "proc_a" "ls_x" "db_write" "high"
          rows <- runStepKind conn
          let key = "obj::proc_a::ls_x"
              own = [r | r@(s, t, _, _, _, _, _, _) <- rows, s == key, t == key]
          assertEqual "exactly one row for the 0-hop pair" 1 (length own)
          let (_, _, ord, _, _, _, stepKind, desc) = case own of
                [r] -> r
                _   -> error "impossible: exactly one row asserted above"
          assertEqual "0-hop ordinal is 0" "0" ord
          assertEqual "0-hop step_kind is source-sink" "source-sink" stepKind
          assertEqual "0-hop description" "taint source and sink (same variable)" desc

    , testCase "duplicate-key collision: parallel edges produce two competing ord-0 source rows" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          -- Two distinct intra-proc def-use edges from the same source
          -- var to two different sink-side defs at the same line,
          -- both landing at leg_ord 0.
          insUse conn "f.srw" "obj" "proc_a" "ls_x" 10 "assign"
          insDef conn "f.srw" "obj" "proc_a" "ls_b" 10
          insSource conn "f.srw" "obj" "proc_a" "ls_x" "db_read"
          insSink   conn "f.srw" "obj" "proc_a" "ls_b" "db_write" "high"
          rows <- runStepKind conn
          let srcKey = "obj::proc_a::ls_x"
              snkKey = "obj::proc_a::ls_b"
              ord0 = [r | r@(s, t, o, _, _, _, _, _) <- rows, s == srcKey, t == snkKey, o == "0"]
          assertBool "at least one ord-0 source row survives" (not (null ord0))
          assertBool "every ord-0 row is labeled source"
            (all (\(_, _, _, _, _, _, sk, _) -> sk == "source") ord0)

    , testCase "cycle not through the seed: taint_step_kind terminates with correct labels" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          -- Same B<->C off-seed cycle shape as taintRules' own cycle test.
          insSource conn "f.srw" "obj" "proc_a" "ls_x" "db_read"
          insSink   conn "f.srw" "obj" "proc_c" "ls_z" "db_write" "high"
          insEdge   conn "obj" "proc_a" "" "obj" "proc_b" "global_write" "ls_x" "ls_x" "ls_y"
          insEdge   conn "obj" "proc_b" "" "obj" "proc_c" "global_write" "ls_y" "ls_y" "ls_z"
          insEdge   conn "obj" "proc_c" "" "obj" "proc_b" "global_write" "ls_z" "ls_z" "ls_y"
          rows <- runStepKind conn
          let srcKey = "obj::proc_a::ls_x"
              snkKey = "obj::proc_c::ls_z"
              path = [r | r@(s, t, _, _, _, _, _, _) <- rows, s == srcKey, t == snkKey]
          assertBool "terminates with at least a source row and a sink row" (length path >= 2)
          assertBool "exactly one row labeled source"
            (length [() | (_, _, _, _, _, _, sk, _) <- path, sk == "source"] == 1)
          assertBool "exactly one row labeled sink"
            (length [() | (_, _, _, _, _, _, sk, _) <- path, sk == "sink"] == 1)

    , testCase "diamond: two equal-length paths pick the lexicographically smaller intermediate" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          -- A -> B -> D and A -> C -> D, both 2 hops. reconstructTaintStepKind's
          -- BFS discovers B before C (adjacency pre-sorted ascending by
          -- (to_key, kind), and "obj::proc_a::ls_b" < "obj::proc_a::ls_c"),
          -- so D's parent must resolve to B's edge, not C's -- a real
          -- diamond, unlike the "duplicate-key collision" case above (which
          -- has only one actual edge despite its name).
          insEdge conn "obj" "proc_a" "" "obj" "proc_a" "global_write" "ls_a" "ls_a" "ls_b"
          insEdge conn "obj" "proc_a" "" "obj" "proc_a" "global_write" "ls_a" "ls_a" "ls_c"
          insEdge conn "obj" "proc_a" "" "obj" "proc_a" "global_write" "ls_b" "ls_b" "ls_d"
          insEdge conn "obj" "proc_a" "" "obj" "proc_a" "global_write" "ls_c" "ls_c" "ls_d"
          insSource conn "f.srw" "obj" "proc_a" "ls_a" "db_read"
          insSink   conn "f.srw" "obj" "proc_a" "ls_d" "db_write" "high"
          rows <- runStepKind conn
          let srcKey = "obj::proc_a::ls_a"
              snkKey = "obj::proc_a::ls_d"
              bKey   = "obj::proc_a::ls_b"
              path = [r | r@(s, t, _, _, _, _, _, _) <- rows, s == srcKey, t == snkKey]
              byOrd = sortOn (\(_, _, o, _, _, _, _, _) -> o) path
          assertEqual "3 rows: source leg, passthrough leg, terminal sink" 3 (length byOrd)
          assertBool "ordinal-0 leg lands at B (the smaller intermediate), not C"
            (case byOrd of
               (_, _, "0", _, lt, _, _, _) : _ -> lt == bKey
               _ -> False)

    , testCase "hub sharing: 2 sources x 1 hub x 2 sinks stays linear, no combinatorial fan-out" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          -- S1, S2 -> H -> T1, T2: 4 confirmed (source, sink) pairs, each a
          -- 2-hop path (3 taint_step_kind rows). This is the shape that
          -- caused the real production incident (doc/plan/171's Postscript)
          -- under the old per-source-distance-table Datalog rules -- the
          -- regression guard here is the row COUNT staying at exactly
          -- 4 pairs x 3 rows, not exploding with shared-hub fan-in/fan-out.
          insEdge conn "obj" "proc_a" "" "obj" "proc_a" "global_write" "ls_s1" "ls_s1" "ls_h"
          insEdge conn "obj" "proc_a" "" "obj" "proc_a" "global_write" "ls_s2" "ls_s2" "ls_h"
          insEdge conn "obj" "proc_a" "" "obj" "proc_a" "global_write" "ls_h"  "ls_h"  "ls_t1"
          insEdge conn "obj" "proc_a" "" "obj" "proc_a" "global_write" "ls_h"  "ls_h"  "ls_t2"
          insSource conn "f.srw" "obj" "proc_a" "ls_s1" "db_read"
          insSource conn "f.srw" "obj" "proc_a" "ls_s2" "db_read"
          insSink   conn "f.srw" "obj" "proc_a" "ls_t1" "db_write" "high"
          insSink   conn "f.srw" "obj" "proc_a" "ls_t2" "db_write" "high"
          rows <- runStepKind conn
          assertEqual "4 confirmed pairs x 3 rows each = 12 total, no fan-out blowup"
            12 (length rows)
    ]

  , testGroup "EdbRelations"
    [ testGroup "taintEdgeIntraRows"
      [ testCase "different var same line produces a def edge" $
          let defs = [Taint.DefRow "f" "obj" "proc_a" "ls_b" "b0" 0 (Just 10) "assign"]
              uses = [Taint.UseRow "f" "obj" "proc_a" "ls_x" "b0" 0 (Just 10) "assign"]
          in assertEqual "one def edge, keyed use -> def"
               [["obj::proc_a::ls_x", "obj::proc_a::ls_b", "def"]]
               (taintEdgeIntraRows defs uses)

      , testCase "same var same line is excluded" $
          let defs = [Taint.DefRow "f" "obj" "proc_a" "ls_x" "b0" 0 (Just 10) "assign"]
              uses = [Taint.UseRow "f" "obj" "proc_a" "ls_x" "b0" 0 (Just 10) "assign"]
          in assertEqual "same-var pair is the assignment itself, not a flow"
               [] (taintEdgeIntraRows defs uses)

      , testCase "def with no line is excluded" $
          let defs = [Taint.DefRow "f" "obj" "proc_a" "ls_b" "b0" 0 Nothing "assign"]
              uses = [Taint.UseRow "f" "obj" "proc_a" "ls_x" "b0" 0 (Just 10) "assign"]
          in assertEqual "a lineless def can never join a use's line"
               [] (taintEdgeIntraRows defs uses)
      ]

    , testGroup "taintEdgeArgRows"
      [ testCase "arg-kind edge included" $
          let e = InterprocEdgeRow "obj" "proc_a" "obj" "proc_b" "arg" "ls_b" "ls_b" "ls_y"
          in assertEqual "" [["obj::proc_a::ls_b", "obj::proc_b::ls_y", "arg"]]
               (taintEdgeArgRows [e])

      , testCase "non-arg-kind edge excluded" $
          let e = InterprocEdgeRow "obj" "proc_a" "obj" "proc_b" "global_write" "ls_b" "ls_b" "ls_y"
          in assertEqual "" [] (taintEdgeArgRows [e])
      ]

    , testGroup "taintEdgeGlobalRows"
      [ testCase "global_write-kind edge keyed by var_name, not caller_context" $
          let e = InterprocEdgeRow "obj" "proc_a" "obj" "proc_b" "global_write" "ls_g" "ls_b" "ls_y"
          in assertEqual "" [["obj::proc_a::ls_g", "obj::proc_b::ls_y", "global"]]
               (taintEdgeGlobalRows [e])

      , testCase "non-global_write-kind edge excluded" $
          let e = InterprocEdgeRow "obj" "proc_a" "obj" "proc_b" "arg" "ls_g" "ls_b" "ls_y"
          in assertEqual "" [] (taintEdgeGlobalRows [e])
      ]

    , testGroup "taintEdgeReturnRows"
      [ testCase "return edge joined against a matching return-kind use at the callee" $
          let e = InterprocEdgeRow "obj" "proc_a" "obj" "proc_b" "return" "" "ls_call" "return"
              u = Taint.UseRow "f" "obj" "proc_b" "ls_ret" "b0" 0 (Just 5) "return"
          in assertEqual "from the callee's return-use, to the caller's call-site context"
               [["obj::proc_b::ls_ret", "obj::proc_a::ls_call", "return"]]
               (taintEdgeReturnRows [u] [e])

      , testCase "return edge with no matching return use produces nothing" $
          let e = InterprocEdgeRow "obj" "proc_a" "obj" "proc_b" "return" "" "ls_call" "return"
              u = Taint.UseRow "f" "obj" "proc_b" "ls_ret" "b0" 0 (Just 5) "assign"
          in assertEqual "" [] (taintEdgeReturnRows [u] [e])
      ]

    , testCase "taintKeyRows: duplicate (object,proc,var) rows collapse to one key" $
        let rows = [TaintKeyRow "obj" "proc_a" "ls_x", TaintKeyRow "obj" "proc_a" "ls_x"]
        in assertEqual "" [["obj::proc_a::ls_x"]] (taintKeyRows rows)
    ]
  ]

-- | Run initSchema + initTaintEdbViews + taintRules +
-- reconstructTaintStepKind (the Haskell BFS-based witness reconstruction,
-- 2026-07-16), query taint_step_kind.
runStepKind :: DuckConn -> IO [(Text, Text, Text, Text, Text, Text, Text, Text)]
runStepKind conn = do
  initSchema conn
  initTaintEdbViews conn
  runRuleSet conn taintRules
  reconstructTaintStepKind conn
  query_ conn
    "SELECT s, t, leg_ord, lf, lt, kind, step_kind, description FROM taint_step_kind"
    :: IO [(Text, Text, Text, Text, Text, Text, Text, Text)]

-- | Project (leg_ord, step_kind, description) for rows at a given ordinal,
-- for a table-driven assertEqual against an expected singleton list.
stepKindTriples
  :: [(Text, Text, Text, Text, Text, Text, Text, Text)]
  -> Int
  -> [(Text, Text, Text)]
stepKindTriples rows n =
  [ (o, sk, desc)
  | (_, _, o, _, _, _, sk, desc) <- rows
  , o == T.pack (show n)
  ]
