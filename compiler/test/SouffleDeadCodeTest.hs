module SouffleDeadCodeTest (tests) where

import PB.Prelude
import PB.Pipeline.Souffle
import PB.Analysis.Rules.Schema (initEdbViews)
import PB.Analysis.Rules.DeadCode
import PB.Pipeline.DuckDb
import PB.Analysis.SchemaCategory (StmtId (..), SchObject (..))
import PB.Analysis.TypeResolve (ResolvedCall (..))
import PB.Analysis.Taint qualified as Taint

import qualified Data.Set  as Set

import Database.DuckDB.Simple (query, query_, Only (..))
import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

phaseATables :: [Text]
phaseATables =
  [ "objects", "procedures", "local_vars", "call_sites", "global_vars"
  , "proc_defs", "proc_uses", "sql_statements", "sql_statement_columns"
  , "sql_statement_filters", "sql_statement_tables", "cat_footprint_columns"
  , "source_files", "parse_errors"
  , "dw_objects", "dw_controls", "dw_retrieve_tables", "dw_retrieve_columns"
  , "dw_write_columns", "dw_where_columns", "dw_joins", "dw_retrieve_where"
  , "catalog_columns", "catalog_pks", "catalog_fks", "catalog_checks"
  ]

-- ---------------------------------------------------------------------------
-- Plan 161 Phase 2b fixtures: seed procedures/resolved_calls/dw_objects/
-- objects the way 'PB.Pipeline.Passes.runPass8' populates them in
-- production, from the same (procs, rawCalls, resolvedCalls, inherits,
-- dwObjects) shape the old Haskell BFS used to take before it was deleted
-- (Plan 161 Phase 2b cutover) -- so each fixture below exercises the
-- SQL-view EDB layer ('initDeadReachEdbViews') against a hand-verified
-- expected dead set (each one cross-checked against the old Haskell BFS
-- before it was deleted, and against the real openpay corpus -- see
-- BACKLOG's Phase 2b session entry).
--
-- Plan 166 Stage 2: inheritance is seeded via @objects.ancestor@ (read by
-- the faithful @inherits@ EDB view), not via the deleted
-- @procedure_overrides@ table. The @inherits@ (child, parent) tuples below
-- become @objects@ rows whose @ancestor@ is the parent.
--
-- Plan 166 Stage 9: this module also covers 'callerCountRules',
-- 'confidenceRel', and 'deadCodeRowsRules' (Stages 4-6) -- previously
-- uncovered in the fast @cabal test@ suite; every prior correctness claim
-- for them rested on manual @pbc --db@ runs against the real corpora.

seedDeadCodeFixture
  :: DuckConn
  -> AppenderPool
  -> [ProcInfo]
  -> [(Text, Text, Text)]           -- ^ raw calls (object, from_proc, to_name)
  -> [(Text, Text, Text, Text)]     -- ^ resolved calls (object, from_proc, target_object, target_proc)
  -> [(Text, Text)]                 -- ^ inherits (child, parent)
  -> Set.Set Text                   -- ^ DW object names
  -> IO ()
seedDeadCodeFixture conn pool procs calls resolved inherits dwObjs = do
  appendProcedures pool
    [ ProcRow "f.srf" (piObject p) (piName p) (piProcType p)
              1 1 "" "" "" "" "" (piCyclomatic p) "confirmed"
    | p <- procs
    ]
  appendDwObjects pool
    [ DwObjectRow "f.srd" o "" "" Nothing | o <- Set.toList dwObjs ]
  appendResolvedCalls conn $
    [ ResolvedCall "f.srf" obj fromProc toName "call" (Just 1) Nothing Nothing "call" "high"
    | (obj, fromProc, toName) <- calls
    ]
    <> [ ResolvedCall "f.srf" obj fromProc (tgtObj <> "." <> tgtProc) "call" (Just 1)
           (Just tgtObj) (Just tgtProc) "call" "high"
       | (obj, fromProc, tgtObj, tgtProc) <- resolved
       ]
  -- Plan 166 Stage 2: seed inheritance as objects.ancestor rows; the
  -- faithful `inherits` EDB view (initDeadReachEdbViews) reads these, and
  -- the `descendant`/`override_edge` IDB rules derive the closure.
  appendObjects pool
    [ ObjectRow "f.sru" "object" child (Just parent) Nothing Nothing "confirmed"
    | (child, parent) <- inherits
    ]

-- | A resolved_calls row builder for the 'EdbRelations' pure-function tests
-- below -- fields these functions never read (file, call_type, resolution
-- kind, confidence, return_type) get fixed placeholder values.
mkResolvedCall :: Text -> Text -> Text -> Maybe (Text, Text) -> Maybe Int -> Taint.ResolvedCallRow
mkResolvedCall obj fromProc toName mTarget mLine = Taint.ResolvedCallRow
  { Taint.rcrFile           = "f.srf"
  , Taint.rcrObject         = obj
  , Taint.rcrFromProc       = fromProc
  , Taint.rcrToName         = toName
  , Taint.rcrCallType       = "call"
  , Taint.rcrCallLine       = mLine
  , Taint.rcrTargetObject   = fst <$> mTarget
  , Taint.rcrTargetProc     = snd <$> mTarget
  , Taint.rcrResolutionKind = "call"
  , Taint.rcrConfidence     = "high"
  , Taint.rcrReturnType     = Nothing
  }

deadObjProcPairs :: DuckConn -> IO (Set.Set (Text, Text))
deadObjProcPairs conn = do
  rows <- query_ conn "SELECT object, proc FROM proc_dead" :: IO [(Text, Text)]
  pure (Set.fromList rows)

-- | Assert 'deadReachRules'' materialized @proc_dead@ contains exactly the
-- given expected (object, proc) pairs.
assertDeadParity
  :: String
  -> [ProcInfo] -> [(Text, Text, Text)] -> [(Text, Text, Text, Text)]
  -> [(Text, Text)] -> Set.Set Text
  -> Set.Set (Text, Text)
  -> TestTree
assertDeadParity name procs calls resolved inherits dwObjs expected =
  testCase name $ withWriteConn ":memory:" $ \conn -> do
    initSchema conn
    withAppenderPool conn phaseATables $ \pool -> do
      seedDeadCodeFixture conn pool procs calls resolved inherits dwObjs
    -- Plan 175 Phase 2: initDeadReachEdbViews now reads procedures/objects/
    -- resolved_calls/dw_objects eagerly (no longer a lazily-evaluated SQL
    -- view) -- must run after the fixture is seeded, not before.
    initDeadReachEdbViews conn
    runRuleSet conn deadReachRules
    got <- deadObjProcPairs conn
    got @?= expected

-- | Assert 'callerCountRules'' materialized @confidence@ relation classifies
-- the given (object, proc) at the expected level, given a fixture seeded the
-- same way 'assertDeadParity' seeds its dead-set fixtures. Mirrors
-- 'PB.Pipeline.Passes.runPass8'\'s real ordering: 'deadReachRules' runs
-- before 'callerCountRules' (via 'runRuleSets', which also resolves this
-- automatically), even though confidence classification itself reads only
-- @proc@/@call_ref@/@resolved_call_edge@, not @proc_dead@.
assertConfidence
  :: String
  -> [ProcInfo] -> [(Text, Text, Text)] -> [(Text, Text, Text, Text)]
  -> (Text, Text) -> Text
  -> TestTree
assertConfidence name procs calls resolved (obj, proc) expectedLevel =
  testCase name $ withWriteConn ":memory:" $ \conn -> do
    initSchema conn
    withAppenderPool conn phaseATables $ \pool -> do
      seedDeadCodeFixture conn pool procs calls resolved [] Set.empty
    initDeadReachEdbViews conn
    runRuleSets (\_ -> pure ()) conn [deadReachRules, callerCountRules]
    rows <- query conn "SELECT level FROM confidence WHERE object = ? AND proc = ?"
              (obj, proc) :: IO [Only Text]
    [ lvl | Only lvl <- rows ] @?= [expectedLevel]

-- | Same behavioral assertions as the old DuckDB-native 'PB.Pipeline.Datalog'
-- test suite -- 'reachesRules'/'liveProcRules' are the same values, now
-- materialized via the Souffle CLI instead of generated SQL. There is no
-- Souffle-backend counterpart to the old "stratify" unit-test group:
-- stratification is Souffle's own job now (see 'PB.Pipeline.Souffle''s
-- module header), so there is nothing left at the Haskell level to assert
-- on there.
tests :: TestTree
tests = testGroup "Souffle.DeadCode"

  [ testGroup "liveProcRules"
    -- Plan 161 Phase 2b cutover: `dead` now reads `proc_dead` (Datalog),
    -- not `dead_code` (Haskell) -- see 'initEdbViews'' doc comment. Every
    -- case here must run 'initDeadReachEdbViews' + 'deadReachRules' before
    -- 'initEdbViews'/'liveProcRules', mirroring the required
    -- 'PB.Pipeline.Passes.runPass11' ordering, so the `dead` view has a
    -- `proc_dead` table to read (even an empty one) before it's queried.
    [ testCase "a stmt whose (object,proc) is not in proc_dead appears in live_proc" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          initDeadReachEdbViews conn
          runRuleSet conn deadReachRules
          appendSchemaObjects conn [ StmtObj (SqlStmtId "f.srf" "obj1" "proc1" 5) ]
          -- initEdbViews now materializes stmt eagerly (Plan 175 Phase 1) --
          -- must run after appendSchemaObjects, not merely after initSchema.
          initEdbViews conn
          runRuleSet conn liveProcRules
          rows <- query_ conn "SELECT object, proc FROM live_proc" :: IO [(Text, Text)]
          assertBool "(obj1,proc1) present" (("obj1", "proc1") `elem` rows)

    , testCase "a stmt whose (object,proc) is in proc_dead is excluded from live_proc" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          -- obj2/proc2: a function with no entry seed and no caller, so
          -- deadReachRules naturally computes it as dead.
          withAppenderPool conn phaseATables $ \pool ->
            appendProcedures pool
              [ ProcRow "f.srf" "obj2" "proc2" "function" 1 1 "" "" "" "" "" (Just 1) "confirmed" ]
          initDeadReachEdbViews conn
          runRuleSet conn deadReachRules
          appendSchemaObjects conn [ StmtObj (SqlStmtId "f.srf" "obj2" "proc2" 9) ]
          initEdbViews conn
          runRuleSet conn liveProcRules
          rows <- query_ conn "SELECT object, proc FROM live_proc" :: IO [(Text, Text)]
          assertBool "(obj2,proc2) absent" (("obj2", "proc2") `notElem` rows)

    , testCase "a DW retrieve StmtObj (no real proc) never appears in live_proc" $
        -- Regression: a 'dw_retrieve'-kind schema_objects row has stmt_proc = NULL,
        -- which can never match proc_dead's (object, proc) rows -- if the
        -- `stmt` EDB view included it, every DW retrieve would vacuously pass the
        -- NOT EXISTS dead check and pollute live_proc with meaningless rows
        -- (found via a real --db smoke run over the openpay corpus).
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          initDeadReachEdbViews conn
          runRuleSet conn deadReachRules
          appendSchemaObjects conn [ StmtObj (DwRetrieveId "d.srd" "d_test") ]
          initEdbViews conn
          runRuleSet conn liveProcRules
          rows <- query_ conn "SELECT object, proc FROM live_proc" :: IO [(Text, Text)]
          assertBool "no dw_retrieve row leaks into live_proc" (null rows)
    ]

  , testGroup "deadReachRules"
    [ testCase "same-object call reaches callee via case-insensitive name match" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          withAppenderPool conn phaseATables $ \pool ->
            seedDeadCodeFixture conn pool
              [ ProcInfo "obj" "ev" "event" (Just 1), ProcInfo "obj" "fn_a" "function" (Just 1) ]
              [ ("obj", "ev", "FN_A") ]
              [] [] Set.empty
          initDeadReachEdbViews conn
          runRuleSet conn deadReachRules
          got <- deadObjProcPairs conn
          assertBool "fn_a not dead" (("obj", "fn_a") `Set.notMember` got)

    , testCase "same-object call reaches callee through a dotted (control-qualified) to_name" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          withAppenderPool conn phaseATables $ \pool ->
            seedDeadCodeFixture conn pool
              [ ProcInfo "obj" "ev" "event" (Just 1), ProcInfo "obj" "fn_a" "function" (Just 1) ]
              [ ("obj", "ev", "dw_1.fn_a") ]
              [] [] Set.empty
          initDeadReachEdbViews conn
          runRuleSet conn deadReachRules
          got <- deadObjProcPairs conn
          assertBool "fn_a not dead" (("obj", "fn_a") `Set.notMember` got)

    , testCase "speculative-confidence procedures (builtin method stubs) are excluded from proc/entry/proc_dead" $
        -- Regression: a real openpay --db run's proc_dead had 45 extra rows,
        -- all speculative-confidence stub procedures registered for PB base
        -- classes (dwobject/powerobject/window/...) -- 'queryProcInfos'
        -- already filters `confidence != 'speculative'`; the raw
        -- `proc`/`entry`/`calls` SQL views must apply the same filter or
        -- they silently disagree.
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          withAppenderPool conn phaseATables $ \pool ->
            appendProcedures pool
              [ ProcRow "builtin" "dwobject" "Retrieve" "function" 1 1 "" "" "" "" "" Nothing "speculative" ]
          initDeadReachEdbViews conn
          procViewRows <- query_ conn "SELECT object, proc FROM proc" :: IO [(Text, Text)]
          entryViewRows <- query_ conn "SELECT object, proc FROM entry" :: IO [(Text, Text)]
          assertBool "speculative stub excluded from proc view" (null procViewRows)
          assertBool "speculative stub excluded from entry view" (null entryViewRows)

    , assertDeadParity "event handlers are seeds"
        [ ProcInfo "obj" "ev" "event" (Just 1) ] [] [] [] Set.empty
        Set.empty

    , assertDeadParity "on handlers are seeds"
        [ ProcInfo "obj" "on_h" "on" (Just 1) ] [] [] [] Set.empty
        Set.empty

    , assertDeadParity "unreachable function is dead"
        [ ProcInfo "obj" "fn" "function" (Just 2) ] [] [] [] Set.empty
        (Set.singleton ("obj", "fn"))

    , assertDeadParity "called function is reachable from seed"
        [ ProcInfo "obj" "ev" "event" (Just 1)
        , ProcInfo "obj" "fn_a" "function" (Just 1)
        , ProcInfo "obj" "fn_b" "function" (Just 1)
        ]
        [ ("obj", "ev", "fn_a"), ("obj", "fn_a", "fn_b") ]
        [] [] Set.empty
        Set.empty

    , assertDeadParity "uncalled function is dead"
        [ ProcInfo "obj" "fn_a" "function" (Just 1), ProcInfo "obj" "fn_b" "function" (Just 1) ]
        [] [] [] Set.empty
        (Set.fromList [("obj", "fn_a"), ("obj", "fn_b")])

    , assertDeadParity "dead chain"
        [ ProcInfo "obj" "fn_c" "function" (Just 1), ProcInfo "obj" "fn_d" "function" (Just 1) ]
        [ ("obj", "fn_c", "fn_d") ]
        [] [] Set.empty
        (Set.fromList [("obj", "fn_c"), ("obj", "fn_d")])

    , assertDeadParity "cross-object reachability"
        [ ProcInfo "obj" "ev" "event" (Just 1), ProcInfo "obj2" "fn_x" "function" Nothing ]
        []
        [ ("obj", "ev", "obj2", "fn_x") ]
        [] Set.empty
        Set.empty

    , assertDeadParity "override propagation"
        [ ProcInfo "obj_base" "base_hook" "event" Nothing
        , ProcInfo "obj_child" "base_hook" "function" Nothing
        ]
        [ ("obj_base", "base_hook", "base_hook") ]
        []
        [ ("obj_child", "obj_base") ]
        Set.empty
        Set.empty

    , assertDeadParity "DW object procedures are seeds"
        [ ProcInfo "obj_dw" "fn_a" "function" Nothing, ProcInfo "obj_dw" "fn_b" "function" Nothing ]
        [ ("obj_dw", "fn_a", "fn_b") ]
        [] [] (Set.singleton "obj_dw")
        Set.empty

    , assertDeadParity "confidence-medium shape: naive callers but no scoped resolution"
        [ ProcInfo "obj" "fn" "function" (Just 2) ]
        [ ("other_obj", "other", "fn") ]
        [] [] Set.empty
        (Set.singleton ("obj", "fn"))

    , assertDeadParity "confidence-low shape: scoped callers present"
        [ ProcInfo "obj" "fn" "function" (Just 2) ]
        [ ("other_obj", "other", "fn") ]
        [ ("other_obj", "other", "obj", "fn") ]
        [] Set.empty
        (Set.singleton ("obj", "fn"))

    , assertDeadParity "sorted by object then name (both dead)"
        [ ProcInfo "obj_z" "fn_b" "function" Nothing, ProcInfo "obj_a" "fn_a" "function" Nothing ]
        [] [] [] Set.empty
        (Set.fromList [("obj_z", "fn_b"), ("obj_a", "fn_a")])

    , assertDeadParity "grandchild override reachable when intermediate lacks the method"
        [ ProcInfo "gp" "hook" "event" Nothing, ProcInfo "child" "hook" "function" Nothing ]
        []
        []
        [ ("p", "gp"), ("child", "p") ]
        Set.empty
        Set.empty
    ]

  , testGroup "callerCountRules / confidenceRel"
    -- Plan 166 Stage 9: previously-uncovered rule sets. Table-driven since
    -- all three share the same seed-fixture-then-assert-confidence-level
    -- shape (CLAUDE.md's table-driven-tests guidance).
    [ assertConfidence "no caller at all -> high confidence"
        [ ProcInfo "obj" "fn" "function" (Just 1) ]
        [] []
        ("obj", "fn") "high"

    , assertConfidence "naive (unresolved) caller only -> medium confidence"
        [ ProcInfo "obj" "fn" "function" (Just 1) ]
        [ ("other_obj", "other", "fn") ]
        []
        ("obj", "fn") "medium"

    , assertConfidence "scoped (resolved) caller present -> low confidence"
        [ ProcInfo "obj" "fn" "function" (Just 1) ]
        [ ("other_obj", "other", "fn") ]
        [ ("other_obj", "other", "obj", "fn") ]
        ("obj", "fn") "low"

    , assertConfidence "mixed-case declared name with a differently-cased naive caller -> medium, not high"
        -- Regression: confidenceRel used to unify a raw-case `proc` variable
        -- (from `proc`/procRel) directly against `has_naive_caller`'s facts,
        -- which are always lowercased (call_ref's LOWER(regexp_extract(...))).
        -- PowerBuilder identifiers are case-insensitive, so a declared name
        -- like `of_Calculate` with a real (differently-cased) unresolved
        -- caller would never match, silently misclassifying it "high" (no
        -- callers) instead of "medium". Fixed by joining confidence through
        -- proc_meta's lowercased proc_lower column instead of proc's raw case.
        [ ProcInfo "obj" "of_Calculate" "function" (Just 1) ]
        [ ("other_obj", "other", "OF_CALCULATE") ]
        []
        ("obj", "of_Calculate") "medium"
    ]

  , testGroup "deadCodeRowsRules / materializeDeadCode"
    [ testCase "caller counts land in dead_code_rows: naive counts every name-match, scoped only resolved edges" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          withAppenderPool conn phaseATables $ \pool ->
            seedDeadCodeFixture conn pool
              [ ProcInfo "obj" "fn" "function" (Just 3) ]
              -- Two distinct unresolved callers of "fn".
              [ ("other_obj", "caller_a", "fn"), ("other_obj", "caller_b", "fn") ]
              -- One resolved call site, from a third caller. A resolved call
              -- also satisfies the naive (name-match) relation -- 'call_ref'
              -- is built from every resolved_calls row regardless of
              -- resolution status (see 'initDeadReachEdbViews'' 'call_ref'
              -- reshaping) -- so naive_n counts all three callers while
              -- scoped_n counts only the one truly-resolved edge.
              [ ("other_obj", "caller_c", "obj", "fn") ]
              [] Set.empty
          initDeadReachEdbViews conn
          runRuleSets (\_ -> pure ()) conn
            [deadReachRules, callerCountRules, deadCodeRowsRules]
          -- dead_code_rows is a raw Souffle-materialized relation: every
          -- column round-trips as TEXT (see PB.Pipeline.DuckDb.materializeDeadCode's
          -- own TRY_CAST doc comment) -- cast explicitly rather than reading
          -- into an Int column directly.
          rows <- query_ conn
            "SELECT TRY_CAST(naive_n AS INTEGER), TRY_CAST(scoped_n AS INTEGER) \
            \FROM dead_code_rows WHERE object = 'obj' AND proc = 'fn'"
            :: IO [(Int, Int)]
          rows @?= [(3, 1)]

    , testCase "overloaded procedure name: materializeDeadCode keeps the highest-cyclomatic row" $
        -- PowerBuilder overloads collapse to one (object, proc_name) pair at
        -- reachability granularity -- two ProcInfo entries sharing the same
        -- (object, name) simulate two overloads with different cyclomatic
        -- complexity. materializeDeadCode's ROW_NUMBER() tie-break must pick
        -- the highest cyclomatic deterministically (see its own doc comment
        -- in PB.Pipeline.DuckDb).
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          withAppenderPool conn phaseATables $ \pool ->
            seedDeadCodeFixture conn pool
              [ ProcInfo "obj" "fn" "function" (Just 3)
              , ProcInfo "obj" "fn" "function" (Just 7)
              ]
            [] [] [] Set.empty
          initDeadReachEdbViews conn
          runRuleSets (\_ -> pure ()) conn
            [deadReachRules, callerCountRules, deadCodeRowsRules]
          materializeDeadCode conn
          rows <- query_ conn
            "SELECT cyclomatic FROM dead_code WHERE object = 'obj' AND proc_name = 'fn'"
            :: IO [Only Int]
          [ c | Only c <- rows ] @?= [7]

    , testCase "overloaded procedure with one unknown cyclomatic: the known value still wins the tie-break" $
        -- Regression: ORDER BY ... DESC without NULLS LAST defaults to
        -- NULLS FIRST in DuckDB, so an overload with an unknown (Nothing)
        -- cyclomatic would sort ahead of a sibling with a real value,
        -- contradicting materializeDeadCode's documented "keeps the
        -- highest-cyclomatic row" tie-break.
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          withAppenderPool conn phaseATables $ \pool ->
            seedDeadCodeFixture conn pool
              [ ProcInfo "obj" "fn" "function" Nothing
              , ProcInfo "obj" "fn" "function" (Just 5)
              ]
            [] [] [] Set.empty
          initDeadReachEdbViews conn
          runRuleSets (\_ -> pure ()) conn
            [deadReachRules, callerCountRules, deadCodeRowsRules]
          materializeDeadCode conn
          rows <- query_ conn
            "SELECT cyclomatic FROM dead_code WHERE object = 'obj' AND proc_name = 'fn'"
            :: IO [Only Int]
          [ c | Only c <- rows ] @?= [5]
    ]

  , -- Plan 175 Phase 2: direct unit tests of 'initDeadReachEdbViews''s pure
    -- reshaping functions -- no 'DuckConn'\/@souffle@ CLI needed, mirroring
    -- 'SouffleSchemaTest.hs''s Phase 1 precedent.
    testGroup "EdbRelations"
    [ testGroup "procRows"
      [ testCase "includes a confirmed procedure" $
          procRows [ProcSummaryRow "obj" "fn" "function" (Just 1) "confirmed"]
            @?= [["obj", "fn"]]
      , testCase "excludes a speculative procedure" $
          procRows [ProcSummaryRow "obj" "fn" "function" (Just 1) "speculative"]
            @?= []
      ]

    , testGroup "procMetaRows"
      [ testCase "renames+lowercases proc_name, coalesces a Just cyclomatic to text" $
          procMetaRows [ProcSummaryRow "obj" "of_Calculate" "function" (Just 3) "confirmed"]
            @?= [["obj", "of_Calculate", "function", "3", "of_calculate"]]
      , testCase "coalesces a Nothing cyclomatic to empty text" $
          procMetaRows [ProcSummaryRow "obj" "fn" "function" Nothing "confirmed"]
            @?= [["obj", "fn", "function", "", "fn"]]
      , testCase "excludes a speculative procedure" $
          procMetaRows [ProcSummaryRow "obj" "fn" "function" (Just 1) "speculative"]
            @?= []
      ]

    , testGroup "inheritsRows"
      [ testCase "renames (object,ancestor) to (child,parent)" $
          inheritsRows [("child_obj", "parent_obj")] @?= [["child_obj", "parent_obj"]]
      ]

    , testGroup "callRefRows"
      [ testCase "extracts + lowercases the segment after the last dot" $
          callRefRows [mkResolvedCall "obj" "ev" "dw_1.FN_A" Nothing Nothing]
            @?= [CallRef "obj" "ev" "fn_a"]
      , testCase "keeps a dotless name unchanged, just lowercased" $
          callRefRows [mkResolvedCall "obj" "ev" "FN_A" Nothing Nothing]
            @?= [CallRef "obj" "ev" "fn_a"]
      , testCase "dedupes two rows sharing (caller_obj,caller_proc,callee_name)" $
          callRefRows [ mkResolvedCall "obj" "ev" "fn_a" Nothing Nothing
                      , mkResolvedCall "obj" "ev" "FN_A" Nothing Nothing
                      ]
            @?= [CallRef "obj" "ev" "fn_a"]
      ]

    , testGroup "resolvedCallEdgeRows"
      [ testCase "includes a fully-resolved call, coalescing a present line to text" $
          resolvedCallEdgeRows [mkResolvedCall "obj" "ev" "x" (Just ("tgt_obj", "tgt_fn")) (Just 42)]
            @?= [ResolvedCallEdge "obj" "ev" "tgt_obj" "tgt_fn" "42"]
      , testCase "coalesces a missing line to empty text" $
          resolvedCallEdgeRows [mkResolvedCall "obj" "ev" "x" (Just ("tgt_obj", "tgt_fn")) Nothing]
            @?= [ResolvedCallEdge "obj" "ev" "tgt_obj" "tgt_fn" ""]
      , testCase "excludes a row with no target_object" $
          resolvedCallEdgeRows
            [ (mkResolvedCall "obj" "ev" "x" Nothing Nothing) { Taint.rcrTargetProc = Just "tgt_fn" } ]
            @?= []
      , testCase "excludes a row with no target_proc" $
          resolvedCallEdgeRows
            [ (mkResolvedCall "obj" "ev" "x" Nothing Nothing) { Taint.rcrTargetObject = Just "tgt_obj" } ]
            @?= []
      , testCase "keeps two duplicate call sites (not deduped)" $
          length (resolvedCallEdgeRows
                    [ mkResolvedCall "obj" "ev" "x" (Just ("tgt_obj", "tgt_fn")) (Just 1)
                    , mkResolvedCall "obj" "ev" "x" (Just ("tgt_obj", "tgt_fn")) (Just 1)
                    ])
            @?= 2
      ]

    , testGroup "entryRows"
      [ testCase "includes an event procedure" $
          entryRows [ProcSummaryRow "obj" "ev" "event" (Just 1) "confirmed"] [] []
            @?= [["obj", "ev"]]
      , testCase "includes an on procedure" $
          entryRows [ProcSummaryRow "obj" "on_h" "on" (Just 1) "confirmed"] [] []
            @?= [["obj", "on_h"]]
      , testCase "excludes a function procedure" $
          entryRows [ProcSummaryRow "obj" "fn" "function" (Just 1) "confirmed"] [] []
            @?= []
      , testCase "excludes a speculative event procedure" $
          entryRows [ProcSummaryRow "obj" "ev" "event" (Just 1) "speculative"] [] []
            @?= []
      , testCase "includes a resolved-call seed whose object is a DW object" $
          entryRows [] [mkResolvedCall "dw_obj" "of_open" "x" Nothing Nothing] ["dw_obj"]
            @?= [["dw_obj", "of_open"]]
      , testCase "excludes a resolved-call seed whose object is not a DW object" $
          entryRows [] [mkResolvedCall "plain_obj" "of_open" "x" Nothing Nothing] ["dw_obj"]
            @?= []
      , testCase "dedupes when both branches produce the same pair" $
          entryRows [ProcSummaryRow "dw_obj" "ev" "event" (Just 1) "confirmed"]
                    [mkResolvedCall "dw_obj" "ev" "x" Nothing Nothing]
                    ["dw_obj"]
            @?= [["dw_obj", "ev"]]
      ]

    , testGroup "callsRows"
      [ testCase "same-object case-insensitive name match against a confirmed procedure" $
          callsRows [CallRef "obj" "ev" "fn_a"]
                    [ProcSummaryRow "obj" "fn_a" "function" (Just 1) "confirmed"]
                    []
            @?= [CallEdge "obj" "ev" "obj" "fn_a"]
      , testCase "excludes a name match against a speculative procedure" $
          callsRows [CallRef "obj" "ev" "fn_a"]
                    [ProcSummaryRow "obj" "fn_a" "function" (Just 1) "speculative"]
                    []
            @?= []
      , testCase "excludes a call_ref with no matching procedure name" $
          callsRows [CallRef "obj" "ev" "fn_missing"]
                    [ProcSummaryRow "obj" "fn_a" "function" (Just 1) "confirmed"]
                    []
            @?= []
      , testCase "includes a resolved_call_edge unconditionally" $
          callsRows [] [] [ResolvedCallEdge "obj" "ev" "obj2" "fn_x" "5"]
            @?= [CallEdge "obj" "ev" "obj2" "fn_x"]
      , testCase "dedupes when a name-match and a resolved edge coincide" $
          callsRows [CallRef "obj" "ev" "fn_a"]
                    [ProcSummaryRow "obj" "fn_a" "function" (Just 1) "confirmed"]
                    [ResolvedCallEdge "obj" "ev" "obj" "fn_a" "9"]
            @?= [CallEdge "obj" "ev" "obj" "fn_a"]
      ]
    ]
  ]
