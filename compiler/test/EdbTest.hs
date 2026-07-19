-- | Regression suite for the five relation materializers that build their
-- raw IDB tables directly in DuckDB (see
-- 'PB.Pipeline.DuckDb.materializeImpliedFkPairs', 'materializeRiskCount',
-- 'materializeLiveProc', 'materializeCallerCounts', 'materializeDeadCodeRows').
-- The behavioral assertions below are the contract for those materializers;
-- the raw IDB tables the downstream consumers reshape are byte-for-byte the
-- same as the hand-verified expected sets.
module EdbTest (tests) where

import PB.Prelude
import PB.Pipeline.DuckDb.Edb
  ( initSchemaEdb, legSourceRows, stmtRows, seedRows
  , joinLegRows, fkRows
  )
import PB.Pipeline.DuckDb.Edb
  ( initDeadCodeEdb
  , procRows, procMetaRows, inheritsRows, callRefRows, resolvedCallEdgeRows
  , entryRows, callsRows, CallRef (..), ResolvedCallEdge (..), CallEdge (..)
  )
import PB.Analysis.DeadCodeReachability (materializeDeadCodeClosure)
import PB.Analysis.SchemaClosure qualified as SchemaClosure
import PB.Pipeline.DuckDb
  ( initSchema, withWriteConn, withAppenderPool, appendSchemaObjects
  , appendSchemaMorphisms, appendProcedures, ProcRow (..)
  , SchMorphismRow (..)
  , materializeDeadCode
  , materializeImpliedFkPairs, materializeRiskCount
  , materializeLiveProc, materializeCallerCounts, materializeDeadCodeRows
  , ProcSummaryRow (..)
  )
import PB.Analysis.SchemaCategory
  ( StmtId (..), SchObject (..), LegKind (..), LegSource (..), SchMorphism (..)
  , CatFkRow (..), schObjectKey
  )
import PB.Analysis.Taint qualified as Taint
import PB.Pipeline.SqlParse (TableRef (..))
import DeadCodeFixtures (ProcInfo (..), seedDeadCodeFixture, mkResolvedCall, phaseATables)

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import Database.DuckDB.Simple (query, query_, execute_, Only (..), Query (..))
import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- | The schema coslice's three relations are produced by the hand-rolled
-- algebraic closure in "PB.Analysis.SchemaClosure"
-- ('legPriority' / 'reachClosure' / 'cosliceClosure'), materialized
-- into the same DuckDB tables by 'SchemaClosure.materializeSchemaClosure'.
-- Their behavioral parity was proven by 'SchemaCorpusBench' against the
-- real corpus before deletion (see doc/plan/182-algebraic-analysis.md §17),
-- and the unit-level assertions now live in "SchemaClosureTest". This file
-- keeps the pure-Haskell EDB reshaping checks ('EdbReshaping') plus the
-- SQL-materialized 'impliedFkPairs' / 'riskCount' rule sets -- and one
-- integration test that the algebraic 'reaches' table feeds 'riskCount'.
tests :: TestTree
tests = testGroup "Edb"

  [ -- Plan 175 Phase 1 pilot: 'legSourceRows'/'stmtRows'/'seedRows' are the
    -- pure Haskell functions that replaced 'initSchemaEdb''s @CREATE VIEW@
    -- SQL for @leg_source@/@stmt@/@seed@. Unlike every other test in this
    -- file, these need no 'DuckConn' at all -- the whole point of the
    -- migration (see doc/plan/175-haskell-edb-reshaping-layer.md's
    -- "Testability win" section).
    testGroup "EdbReshaping"
    [ testCase "legSourceRows renames from_key/to_key/leg_kind to x/y/kind, drops leg_source" $
        legSourceRows [SchMorphismRow "col:a.x" "stmt:sql:f:o:p:5" "reads" "sql_text"]
          @?= [["col:a.x", "stmt:sql:f:o:p:5", "reads"]]

    , testCase "stmtRows: a SqlStmtId row becomes (file,object,proc,line)" $
        stmtRows [StmtObj (SqlStmtId "f.srf" "obj1" "proc1" 5)]
          @?= [["f.srf", "obj1", "proc1", "5"]]

    , testCase "stmtRows: a DwRetrieveId row is excluded (stmt_proc always NULL, would pollute live_proc)" $
        stmtRows [StmtObj (DwRetrieveId "d.srd" "d_test")] @?= []

    , testCase "stmtRows: a ColumnObj row is excluded" $
        stmtRows [ColumnObj (TableRef Nothing "a") "x"] @?= []

    , testCase "seedRows: a ColumnObj row becomes its schObjectKey" $
        seedRows [ColumnObj (TableRef Nothing "a") "x"]
          @?= [[schObjectKey (ColumnObj (TableRef Nothing "a") "x")]]

    , testCase "seedRows: a StmtObj row is excluded" $
        seedRows [StmtObj (SqlStmtId "f.srf" "obj1" "proc1" 5)] @?= []

    , -- Plan 161 Phase 3a: implied_fk_pairs(X, Y) :- join_leg(X, Y), !fk(X, Y),
      -- !fk(Y, X). join_leg/fk are pure EDB (initSchemaEdb), so this rule set
      -- runs alone -- no dependency on the deleted legRules/reachesRules.
      testCase "joinLegRows: a dw_join-sourced row becomes (x, y), dropping kind/source" $
        joinLegRows [SchMorphismRow "col:a.x" "col:b.y" "fk" "dw_join"]
          @?= [["col:a.x", "col:b.y"]]

    , testCase "joinLegRows: a ddl_fk-sourced row (same leg_kind) is excluded" $
        joinLegRows [SchMorphismRow "col:a.x" "col:b.y" "fk" "ddl_fk"] @?= []

    , testCase "joinLegRows: a reads-sourced row is excluded" $
        joinLegRows [SchMorphismRow "col:a.x" "stmt:sql:f:o:p:5" "reads" "sql_text"] @?= []

    , testCase "fkRows: a catalog_fks row becomes the same schObjectKey pair buildSchema's own SrcDdlFk leg uses" $
        fkRows [CatFkRow Nothing "a" "x" Nothing "b" "y"]
          @?= [ [ schObjectKey (ColumnObj (TableRef Nothing "a") "x")
                , schObjectKey (ColumnObj (TableRef Nothing "b") "y")
                ]
              ]
    ]

  , -- implied_fk_pairs(X, Y) :- join_leg(X, Y), !fk(X, Y), !fk(Y, X).
    -- Materialized directly in DuckDB by 'materializeImpliedFkPairs'.
    -- join_leg/fk are pure EDB (initSchemaEdb).
    testGroup "impliedFkPairs"
    [ testCase "a DW-join edge with no declared FK in either direction is reported" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          let colA = ColumnObj (TableRef Nothing "a") "x"
              colB = ColumnObj (TableRef Nothing "b") "y"
          appendSchemaMorphisms conn [ SchMorphism colA colB LegFk SrcDwJoin ]
          initSchemaEdb conn
          materializeImpliedFkPairs conn
          rows <- query_ conn "SELECT x, y FROM implied_fk_pairs" :: IO [(Text, Text)]
          rows @?= [(schObjectKey colA, schObjectKey colB)]

    , testCase "a DW-join edge matching a declared FK in the SAME direction is not reported" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          let colA = ColumnObj (TableRef Nothing "a") "x"
              colB = ColumnObj (TableRef Nothing "b") "y"
          appendSchemaMorphisms conn [ SchMorphism colA colB LegFk SrcDwJoin ]
          _ <- execute_ conn (Query "INSERT INTO catalog_fks VALUES ('c1', NULL, 'a', 'x', NULL, 'b', 'y', 0)")
          initSchemaEdb conn
          materializeImpliedFkPairs conn
          rows <- query_ conn "SELECT x, y FROM implied_fk_pairs" :: IO [(Text, Text)]
          rows @?= []

    , testCase "a DW-join edge matching a declared FK in the REVERSED direction is not reported" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          let colA = ColumnObj (TableRef Nothing "a") "x"
              colB = ColumnObj (TableRef Nothing "b") "y"
          appendSchemaMorphisms conn [ SchMorphism colA colB LegFk SrcDwJoin ]
          -- FK declared b.y -> a.x: the opposite orientation from the join edge.
          _ <- execute_ conn (Query "INSERT INTO catalog_fks VALUES ('c1', NULL, 'b', 'y', NULL, 'a', 'x', 0)")
          initSchemaEdb conn
          materializeImpliedFkPairs conn
          rows <- query_ conn "SELECT x, y FROM implied_fk_pairs" :: IO [(Text, Text)]
          rows @?= []

    , testCase "a declared DDL FK with no DW join is not spuriously reported" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          _ <- execute_ conn (Query "INSERT INTO catalog_fks VALUES ('c1', NULL, 'a', 'x', NULL, 'b', 'y', 0)")
          initSchemaEdb conn
          materializeImpliedFkPairs conn
          rows <- query_ conn "SELECT x, y FROM implied_fk_pairs" :: IO [(Text, Text)]
          rows @?= []
    ]

  , -- risk_count(X, N) aggregates the downstream footprint over the 'reaches'
    -- relation. 'reaches' is an algebraic EDB table materialized by
    -- 'SchemaClosure.materializeSchemaClosure' (which also writes
    -- path_leg_fwd/path_leg_back). This group is the integration gate that the
    -- algebraic closure feeds the SQL 'materializeRiskCount' correctly.
    testGroup "riskCount"
    [ testCase "risk_count reports each node's downstream footprint, omitting unreachable nodes" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          let colA = ColumnObj (TableRef Nothing "a") "x"
              colB = ColumnObj (TableRef Nothing "b") "y"
              colC = ColumnObj (TableRef Nothing "c") "z"
          appendSchemaMorphisms conn
            [ SchMorphism colA colB LegWrites SrcSqlText
            , SchMorphism colB colC LegWrites SrcSqlText
            ]
          initSchemaEdb conn
          SchemaClosure.materializeSchemaClosure conn
          materializeRiskCount conn
          rows <- query_ conn "SELECT x, n FROM risk_count" :: IO [(Text, Text)]
          let byNode = Map.fromList rows
          Map.lookup (schObjectKey colA) byNode @?= Just "2"
          Map.lookup (schObjectKey colB) byNode @?= Just "1"
          Map.lookup (schObjectKey colC) byNode @?= Nothing

    , -- Mirrors the former reachesRules' cyclic 2-node saturation test:
      -- risk_count must terminate with a stable, finite count on a cyclic
      -- graph, not just on a DAG.
      testCase "cyclic graph terminates with a stable, finite downstream count" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          let colA = ColumnObj (TableRef Nothing "a") "x"
              colB = ColumnObj (TableRef Nothing "b") "y"
          appendSchemaMorphisms conn
            [ SchMorphism colA colB LegFk SrcDdlFk
            , SchMorphism colB colA LegFk SrcDdlFk
            ]
          initSchemaEdb conn
          SchemaClosure.materializeSchemaClosure conn
          materializeRiskCount conn
          rows <- query_ conn "SELECT x, n FROM risk_count" :: IO [(Text, Text)]
          let byNode = Map.fromList rows
          Map.lookup (schObjectKey colA) byNode @?= Just "2"
          Map.lookup (schObjectKey colB) byNode @?= Just "2"
    ]

  , testGroup "DeadCode"
    [ testGroup "liveProc"
      -- Plan 161 Phase 2b cutover: `dead` now reads `proc_dead` (materialized
      -- by 'materializeDeadCodeClosure', algebraic since the Plan 182 item 6
      -- cutover), not `dead_code` (Haskell) -- see 'initSchemaEdb'' doc comment.
      -- Every case here must run 'initDeadCodeEdb' +
      -- 'materializeDeadCodeClosure' before 'initSchemaEdb'/'materializeLiveProc',
      -- mirroring the required 'PB.Pipeline.Passes.materializeAllEdbViews'
      -- ordering, so the `dead` view has a `proc_dead` table to read (even an
      -- empty one) before it's queried.
      [ testCase "a stmt whose (object,proc) is not in proc_dead appears in live_proc" $
          withWriteConn ":memory:" $ \conn -> do
            initSchema conn
            initDeadCodeEdb conn
            materializeDeadCodeClosure conn
            appendSchemaObjects conn [ StmtObj (SqlStmtId "f.srf" "obj1" "proc1" 5) ]
            -- initSchemaEdb now materializes stmt eagerly (Plan 175 Phase 1) --
            -- must run after appendSchemaObjects, not merely after initSchema.
            initSchemaEdb conn
            materializeLiveProc conn
            rows <- query_ conn "SELECT object, proc FROM live_proc" :: IO [(Text, Text)]
            assertBool "(obj1,proc1) present" (("obj1", "proc1") `elem` rows)

      , testCase "a stmt whose (object,proc) is in proc_dead is excluded from live_proc" $
          withWriteConn ":memory:" $ \conn -> do
            initSchema conn
            -- obj2/proc2: a function with no entry seed and no caller, so
            -- materializeDeadCodeClosure naturally computes it as dead.
            withAppenderPool conn phaseATables $ \pool ->
              appendProcedures pool
                [ ProcRow "f.srf" "obj2" "proc2" "function" 1 1 "" "" "" "" "" (Just 1) "confirmed" ]
            initDeadCodeEdb conn
            materializeDeadCodeClosure conn
            appendSchemaObjects conn [ StmtObj (SqlStmtId "f.srf" "obj2" "proc2" 9) ]
            initSchemaEdb conn
            materializeLiveProc conn
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
            initDeadCodeEdb conn
            materializeDeadCodeClosure conn
            appendSchemaObjects conn [ StmtObj (DwRetrieveId "d.srd" "d_test") ]
            initSchemaEdb conn
            materializeLiveProc conn
            rows <- query_ conn "SELECT object, proc FROM live_proc" :: IO [(Text, Text)]
            assertBool "no dw_retrieve row leaks into live_proc" (null rows)
      ]

    , -- The full proc_dead-shape fixture set previously here (event-handler
      -- seeds, dead chains, override propagation, cross-object reachability,
      -- confidence-shape combinations, case-insensitive/dotted call-name
      -- matching) moved to 'DeadCodeReachabilityTest' as golden assertions --
      -- 'deadReach' is the sole implementation, so there is no second
      -- implementation left to oracle-diff against.
      testGroup "EDB view filtering"
      [ testCase "speculative-confidence procedures (builtin method stubs) are excluded from proc/entry/proc_dead" $
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
            initDeadCodeEdb conn
            procViewRows <- query_ conn "SELECT object, proc FROM proc" :: IO [(Text, Text)]
            entryViewRows <- query_ conn "SELECT object, proc FROM entry" :: IO [(Text, Text)]
            assertBool "speculative stub excluded from proc view" (null procViewRows)
            assertBool "speculative stub excluded from entry view" (null entryViewRows)
      ]

    , testGroup "callerCounts / confidence"
      -- Previously-uncovered caller-count levels. Table-driven since all three
      -- share the same seed-fixture-then-assert-confidence-level shape
      -- (CLAUDE.md's table-driven-tests guidance). Materialized by
      -- 'materializeCallerCounts'.
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
          -- Regression: confidence used to unify a raw-case `proc` variable
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

    , testGroup "deadCodeRows / materializeDeadCode"
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
                -- resolution status (see 'initDeadCodeEdb'' 'call_ref'
                -- reshaping) -- so naive_n counts all three callers while
                -- scoped_n counts only the one truly-resolved edge.
                [ ("other_obj", "caller_c", "obj", "fn") ]
                [] Set.empty
            initDeadCodeEdb conn
            materializeDeadCodeClosure conn
            materializeCallerCounts conn
            materializeDeadCodeRows conn
            -- dead_code_rows is a raw materialized relation: every
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
            initDeadCodeEdb conn
            materializeDeadCodeClosure conn
            materializeCallerCounts conn
            materializeDeadCodeRows conn
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
            initDeadCodeEdb conn
            materializeDeadCodeClosure conn
            materializeCallerCounts conn
            materializeDeadCodeRows conn
            materializeDeadCode conn
            rows <- query_ conn
              "SELECT cyclomatic FROM dead_code WHERE object = 'obj' AND proc_name = 'fn'"
              :: IO [Only Int]
            [ c | Only c <- rows ] @?= [5]
      ]

    , -- Plan 175 Phase 2: direct unit tests of 'initDeadCodeEdb''s pure
      -- reshaping functions -- no 'DuckConn'\/external engine needed, mirroring
      -- 'SchemaClosureTest''s Phase 1 precedent.
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
  ]

-- | Assert 'materializeCallerCounts'' materialized @confidence@ relation
-- classifies the given (object, proc) at the expected level. Confidence
-- classification reads only @proc@\/@call_ref@\/@resolved_call_edge@, not
-- @proc_dead@, so no dead-code closure needs to run first.
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
    initDeadCodeEdb conn
    materializeCallerCounts conn
    rows <- query conn "SELECT level FROM confidence WHERE object = ? AND proc = ?"
              (obj, proc) :: IO [Only Text]
    [ lvl | Only lvl <- rows ] @?= [expectedLevel]
