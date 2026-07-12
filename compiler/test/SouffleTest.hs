module SouffleTest (tests) where

import PB.Prelude
import PB.Pipeline.Souffle
import PB.Analysis.Rules.Schema
import PB.Analysis.Rules.DeadCode
import PB.Pipeline.DuckDb
import PB.Analysis.SchemaCategory
  ( StmtId (..), SchObject (..), LegKind (..), LegSource (..), SchMorphism (..)
  , SchemaInputs (..), SqlColRow (..), SchGraph (..)
  , buildSchema, blastRadius, schObjectKey, spTo
  )
import PB.Analysis.TypeResolve (ResolvedCall (..))
import PB.Pipeline.SqlParse (TableRef (..))

import qualified Data.Set  as Set

import Database.DuckDB.Simple (query, query_, Only (..))
import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

emptyInputs :: SchemaInputs
emptyInputs = SchemaInputs [] [] [] [] [] [] [] [] Nothing

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

seedDeadCodeFixture
  :: DuckConn
  -> [ProcInfo]
  -> [(Text, Text, Text)]           -- ^ raw calls (object, from_proc, to_name)
  -> [(Text, Text, Text, Text)]     -- ^ resolved calls (object, from_proc, target_object, target_proc)
  -> [(Text, Text)]                 -- ^ inherits (child, parent)
  -> Set.Set Text                   -- ^ DW object names
  -> IO ()
seedDeadCodeFixture conn procs calls resolved inherits dwObjs = do
  appendProcedures conn
    [ ProcRow "f.srf" (piObject p) (piName p) (piProcType p)
              1 1 "" "" "" "" "" (piCyclomatic p) "confirmed"
    | p <- procs
    ]
  appendDwObjects conn
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
  appendObjects conn
    [ ObjectRow "f.sru" "object" child (Just parent) Nothing Nothing "confirmed"
    | (child, parent) <- inherits
    ]

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
    initDeadReachEdbViews conn
    seedDeadCodeFixture conn procs calls resolved inherits dwObjs
    runRuleSet conn deadReachRules
    got <- deadObjProcPairs conn
    got @?= expected

-- | Same behavioral assertions as the old DuckDB-native 'PB.Pipeline.Datalog'
-- test suite -- 'reachesRules'/'liveProcRules' are the same values, now
-- materialized via the Souffle CLI instead of generated SQL. There is no
-- Souffle-backend counterpart to the old "stratify" unit-test group:
-- stratification is Souffle's own job now (see 'PB.Pipeline.Souffle''s
-- module header), so there is nothing left at the Haskell level to assert
-- on there.
tests :: TestTree
tests = testGroup "Souffle"

  [ testGroup "reachesRules"
    [ testCase "two-hop chain: reaches contains both hops and the transitive pair" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          initEdbViews conn
          let colA = ColumnObj (TableRef Nothing "a") "x"
              colB = ColumnObj (TableRef Nothing "b") "y"
              sid  = SqlStmtId "f.srf" "obj" "proc" 5
              inp = emptyInputs
                { inSqlColumns =
                    [ SqlColRow sid Nothing (Just "a") "x" False
                    , SqlColRow sid Nothing (Just "b") "y" True
                    ]
                }
              sch = buildSchema inp
          appendSchemaMorphisms conn (sgLegs sch)
          runRuleSet conn reachesRules
          rows <- query_ conn "SELECT x, y FROM reaches" :: IO [(Text, Text)]
          let got = Set.fromList rows
              colAKey = schObjectKey colA
              stmtKey = schObjectKey (StmtObj sid)
              colBKey = schObjectKey colB
          assertBool "colA -> stmt present"  (Set.member (colAKey, stmtKey) got)
          assertBool "stmt -> colB present"  (Set.member (stmtKey, colBKey) got)
          assertBool "colA -> colB present (transitive)" (Set.member (colAKey, colBKey) got)

    , testCase "cyclic 2-node graph saturates and terminates (all 4 ordered pairs, no more)" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          initEdbViews conn
          let colA = ColumnObj (TableRef Nothing "a") "x"
              colB = ColumnObj (TableRef Nothing "b") "y"
              colAKey = schObjectKey colA
              colBKey = schObjectKey colB
          appendSchemaMorphisms conn
            [ SchMorphism colA colB LegFk SrcDdlFk
            , SchMorphism colB colA LegFk SrcDdlFk
            ]
          runRuleSet conn reachesRules
          rows <- query_ conn "SELECT x, y FROM reaches" :: IO [(Text, Text)]
          let got = Set.fromList rows
          got @?= Set.fromList
            [ (colAKey, colAKey), (colAKey, colBKey)
            , (colBKey, colAKey), (colBKey, colBKey)
            ]

    , testCase "reaches's non-identity endpoints match SchemaCategory.blastRadius" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          initEdbViews conn
          let colA = ColumnObj (TableRef Nothing "a") "x"
              sid  = SqlStmtId "f.srf" "obj" "proc" 5
              inp = emptyInputs
                { inSqlColumns =
                    [ SqlColRow sid Nothing (Just "a") "x" False
                    , SqlColRow sid Nothing (Just "b") "y" True
                    ]
                }
              sch = buildSchema inp
              colAKey = schObjectKey colA
              haskellEndpoints = Set.fromList
                [ schObjectKey (spTo p) | p <- blastRadius sch colA, spTo p /= colA ]
          appendSchemaMorphisms conn (sgLegs sch)
          runRuleSet conn reachesRules
          rows <- query conn "SELECT y FROM reaches WHERE x = ?" (Only colAKey) :: IO [Only Text]
          let datalogEndpoints = Set.fromList [ y | Only y <- rows ]
          datalogEndpoints @?= haskellEndpoints
    ]

  , testGroup "liveProcRules"
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
          initEdbViews conn
          appendSchemaObjects conn [ StmtObj (SqlStmtId "f.srf" "obj1" "proc1" 5) ]
          runRuleSet conn liveProcRules
          rows <- query_ conn "SELECT object, proc FROM live_proc" :: IO [(Text, Text)]
          assertBool "(obj1,proc1) present" (("obj1", "proc1") `elem` rows)

    , testCase "a stmt whose (object,proc) is in proc_dead is excluded from live_proc" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          initDeadReachEdbViews conn
          -- obj2/proc2: a function with no entry seed and no caller, so
          -- deadReachRules naturally computes it as dead.
          appendProcedures conn
            [ ProcRow "f.srf" "obj2" "proc2" "function" 1 1 "" "" "" "" "" (Just 1) "confirmed" ]
          runRuleSet conn deadReachRules
          initEdbViews conn
          appendSchemaObjects conn [ StmtObj (SqlStmtId "f.srf" "obj2" "proc2" 9) ]
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
          initEdbViews conn
          appendSchemaObjects conn [ StmtObj (DwRetrieveId "d.srd" "d_test") ]
          runRuleSet conn liveProcRules
          rows <- query_ conn "SELECT object, proc FROM live_proc" :: IO [(Text, Text)]
          assertBool "no dw_retrieve row leaks into live_proc" (null rows)
    ]

  , testGroup "deadReachRules"
    [ testCase "same-object call reaches callee via case-insensitive name match" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          initDeadReachEdbViews conn
          seedDeadCodeFixture conn
            [ ProcInfo "obj" "ev" "event" (Just 1), ProcInfo "obj" "fn_a" "function" (Just 1) ]
            [ ("obj", "ev", "FN_A") ]
            [] [] Set.empty
          runRuleSet conn deadReachRules
          got <- deadObjProcPairs conn
          assertBool "fn_a not dead" (("obj", "fn_a") `Set.notMember` got)

    , testCase "same-object call reaches callee through a dotted (control-qualified) to_name" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          initDeadReachEdbViews conn
          seedDeadCodeFixture conn
            [ ProcInfo "obj" "ev" "event" (Just 1), ProcInfo "obj" "fn_a" "function" (Just 1) ]
            [ ("obj", "ev", "dw_1.fn_a") ]
            [] [] Set.empty
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
          initDeadReachEdbViews conn
          appendProcedures conn
            [ ProcRow "builtin" "dwobject" "Retrieve" "function" 1 1 "" "" "" "" "" Nothing "speculative" ]
          procRows <- query_ conn "SELECT object, proc FROM proc" :: IO [(Text, Text)]
          entryRows <- query_ conn "SELECT object, proc FROM entry" :: IO [(Text, Text)]
          assertBool "speculative stub excluded from proc view" (null procRows)
          assertBool "speculative stub excluded from entry view" (null entryRows)

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
  ]
