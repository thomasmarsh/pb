-- | Regression suite for the relation materializers that build their
-- raw derived tables directly in DuckDB (see
-- 'PB.Pipeline.DuckDb.materializeImpliedFkPairs', 'materializeRiskCount',
-- 'materializeLiveProc', 'materializeDeadCode').
-- The behavioral assertions below are the contract for those materializers;
-- the raw derived tables the downstream consumers reshape are byte-for-byte the
-- same as the hand-verified expected sets.
module RelationsTest (tests) where

import PB.Prelude
import PB.Pipeline.DuckDb.Relations
  ( initSchemaRelations, SchemaInputRows (..), legSourceRows, stmtRows, seedRows
  , joinLegRows, fkRows
  )
import PB.Pipeline.DuckDb.Relations
  ( initDeadCodeRelations, DeadCodeInputRows (..)
  , procRows, procMetaRows, inheritsRows, callRefRows, resolvedCallEdgeRows
  , entryRows, callsRows, CallRef (..), ResolvedCallEdge (..), CallEdge (..)
  )
import PB.Pipeline.DuckDb.Relations (TypeCoverageStats (..), typeCoverageStats)
import PB.Analysis.DeadCodeReachability (materializeDeadCodeClosure)
import PB.Analysis.SchemaClosure qualified as SchemaClosure
import PB.Pipeline.DuckDb
  ( initSchema, withHandle
  , queryHandle, executeHandle, inMemory
  )
import PB.Pipeline.DuckDb.Appender (withAppenderPool)
import PB.Pipeline.DuckDb.PhaseA
  ( appendProcedures, ProcRow (..)
  , appendIdentifierTokens, IdentifierTokenRow (..)
  , appendVarRefs
  )
import PB.Pipeline.DuckDb.PhaseB.Query
  ( SchMorphismRow (..), ProcSummaryRow (..), queryCatFks
  , queryProcedures, queryResolvedCalls, queryObjectAncestors, queryDwObjects
  , querySchemaMorphismRows, querySchemaObjects
  , DeadCodeClosureReady (..), SchemaClosureReady (..)
  )
import PB.Pipeline.DuckDb.PhaseB.Append (appendSchemaObjects, appendSchemaMorphisms, appendResolvedCalls)
import PB.Analysis.TypeResolve (ResolvedVarRef (..), ResolvedCall (..))
import PB.Lexing.Token (SourceSpan (..))
import PB.Pipeline.DuckDb.Materialize
  ( materializeDeadCode
  , materializeImpliedFkPairs, materializeRiskCount
  , materializeLiveProc
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

import Database.DuckDB.Simple (Only (..), Query (..))
import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- | The schema coslice's three relations are produced by the hand-rolled
-- algebraic closure in "PB.Analysis.SchemaClosure"
-- ('legPriority' / 'reachClosure' / 'cosliceClosure'), materialized
-- into the same DuckDB tables by 'SchemaClosure.materializeSchemaClosure'.
-- Their behavioral parity was proven by 'SchemaCorpusBench' against the
-- real corpus before deletion (see doc/plan/182-algebraic-analysis.md §17),
-- and the unit-level assertions now live in "SchemaClosureTest". This file
-- keeps the pure-Haskell relation reshaping checks ('RelationReshaping') plus the
-- SQL-materialized 'impliedFkPairs' / 'riskCount' rule sets -- and one
-- integration test that the algebraic 'reaches' table feeds 'riskCount'.
tests :: TestTree
tests = testGroup "Relations"

  [ -- Plan 175 Phase 1 pilot: 'legSourceRows'/'stmtRows'/'seedRows' are the
    -- pure Haskell functions that replaced 'initSchemaRelations''s @CREATE VIEW@
    -- SQL for @leg_source@/@stmt@/@seed@. Unlike every other test in this
    -- file, these need no 'Handle' at all -- the whole point of the
    -- migration (see doc/plan/175-haskell-edb-reshaping-layer.md's
    -- "Testability win" section).
    testGroup "RelationReshaping"
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
      -- !fk(Y, X). join_leg/fk are pure input relations (initSchemaRelations), so this rule set
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
    -- join_leg/fk are pure input relations (initSchemaRelations).
    testGroup "impliedFkPairs"
    [ testCase "a DW-join edge with no declared FK in either direction is reported" $
        withHandle inMemory $ \conn -> do
          initSchema conn
          let colA = ColumnObj (TableRef Nothing "a") "x"
              colB = ColumnObj (TableRef Nothing "b") "y"
          appendSchemaMorphisms conn [ SchMorphism colA colB LegFk SrcDwJoin ]
          schRows <- initSchemaRelations conn []
          materializeImpliedFkPairs conn schRows
          rows <- queryHandle conn "SELECT x, y FROM implied_fk_pairs" :: IO [(Text, Text)]
          rows @?= [(schObjectKey colA, schObjectKey colB)]

    , testCase "a DW-join edge matching a declared FK in the SAME direction is not reported" $
        withHandle inMemory $ \conn -> do
          initSchema conn
          let colA = ColumnObj (TableRef Nothing "a") "x"
              colB = ColumnObj (TableRef Nothing "b") "y"
          appendSchemaMorphisms conn [ SchMorphism colA colB LegFk SrcDwJoin ]
          _ <- executeHandle conn (Query "INSERT INTO catalog_fks VALUES ('c1', NULL, 'a', 'x', NULL, 'b', 'y', 0)")
          catFks <- queryCatFks conn
          schRows <- initSchemaRelations conn catFks
          materializeImpliedFkPairs conn schRows
          rows <- queryHandle conn "SELECT x, y FROM implied_fk_pairs" :: IO [(Text, Text)]
          rows @?= []

    , testCase "a DW-join edge matching a declared FK in the REVERSED direction is not reported" $
        withHandle inMemory $ \conn -> do
          initSchema conn
          let colA = ColumnObj (TableRef Nothing "a") "x"
              colB = ColumnObj (TableRef Nothing "b") "y"
          appendSchemaMorphisms conn [ SchMorphism colA colB LegFk SrcDwJoin ]
          -- FK declared b.y -> a.x: the opposite orientation from the join edge.
          _ <- executeHandle conn (Query "INSERT INTO catalog_fks VALUES ('c1', NULL, 'b', 'y', NULL, 'a', 'x', 0)")
          catFks <- queryCatFks conn
          schRows <- initSchemaRelations conn catFks
          materializeImpliedFkPairs conn schRows
          rows <- queryHandle conn "SELECT x, y FROM implied_fk_pairs" :: IO [(Text, Text)]
          rows @?= []

    , testCase "a declared DDL FK with no DW join is not spuriously reported" $
        withHandle inMemory $ \conn -> do
          initSchema conn
          _ <- executeHandle conn (Query "INSERT INTO catalog_fks VALUES ('c1', NULL, 'a', 'x', NULL, 'b', 'y', 0)")
          catFks <- queryCatFks conn
          schRows <- initSchemaRelations conn catFks
          materializeImpliedFkPairs conn schRows
          rows <- queryHandle conn "SELECT x, y FROM implied_fk_pairs" :: IO [(Text, Text)]
          rows @?= []
    ]

  , -- risk_count(X, N) aggregates the downstream footprint over the 'reaches'
    -- relation. 'reaches' is an algebraic input table materialized by
    -- 'SchemaClosure.materializeSchemaClosure' (which also writes
    -- path_leg_fwd/path_leg_back). This group is the integration gate that the
    -- algebraic closure feeds the SQL 'materializeRiskCount' correctly.
    testGroup "riskCount"
    [ testCase "risk_count reports each node's downstream footprint, omitting unreachable nodes" $
        withHandle inMemory $ \conn -> do
          initSchema conn
          let colA = ColumnObj (TableRef Nothing "a") "x"
              colB = ColumnObj (TableRef Nothing "b") "y"
              colC = ColumnObj (TableRef Nothing "c") "z"
          appendSchemaMorphisms conn
            [ SchMorphism colA colB LegWrites SrcSqlText
            , SchMorphism colB colC LegWrites SrcSqlText
            ]
          schRows <- initSchemaRelations conn []
          SchemaClosure.materializeSchemaClosure schRows conn
          materializeRiskCount conn (SchemaClosureReady ())
          rows <- queryHandle conn "SELECT x, n FROM risk_count" :: IO [(Text, Text)]
          let byNode = Map.fromList rows
          Map.lookup (schObjectKey colA) byNode @?= Just "2"
          Map.lookup (schObjectKey colB) byNode @?= Just "1"
          Map.lookup (schObjectKey colC) byNode @?= Nothing

    , -- Mirrors the former reachesRules' cyclic 2-node saturation test:
      -- risk_count must terminate with a stable, finite count on a cyclic
      -- graph, not just on a DAG.
      testCase "cyclic graph terminates with a stable, finite downstream count" $
        withHandle inMemory $ \conn -> do
          initSchema conn
          let colA = ColumnObj (TableRef Nothing "a") "x"
              colB = ColumnObj (TableRef Nothing "b") "y"
          appendSchemaMorphisms conn
            [ SchMorphism colA colB LegFk SrcDdlFk
            , SchMorphism colB colA LegFk SrcDdlFk
            ]
          schRows <- initSchemaRelations conn []
          SchemaClosure.materializeSchemaClosure schRows conn
          materializeRiskCount conn (SchemaClosureReady ())
          rows <- queryHandle conn "SELECT x, n FROM risk_count" :: IO [(Text, Text)]
          let byNode = Map.fromList rows
          Map.lookup (schObjectKey colA) byNode @?= Just "2"
          Map.lookup (schObjectKey colB) byNode @?= Just "2"
    ]

  , testGroup "DeadCode"
    [ testGroup "liveProc"
      -- Plan 161 Phase 2b cutover: `dead` now reads `proc_dead` (materialized
      -- by 'materializeDeadCodeClosure', algebraic since the Plan 182 item 6
      -- cutover), not `dead_code` (Haskell) -- see 'initSchemaRelations'' doc comment.
      -- Every case here must run 'initDeadCodeRelations' +
      -- 'materializeDeadCodeClosure' before 'initSchemaRelations'/'materializeLiveProc',
      -- mirroring the required 'PB.Pipeline.Passes.initDeadCodeInput'/'computeDeadCodeClosure'/'initSchemaInput'
      -- ordering, so the `dead` view has a `proc_dead` table to read (even an
      -- empty one) before it's queried.
      [ testCase "a stmt whose (object,proc) is not in proc_dead appears in live_proc" $
          withHandle inMemory $ \conn -> do
            initSchema conn
            dcRows <- initDeadCodeRelations conn
            materializeDeadCodeClosure dcRows conn
            appendSchemaObjects conn [ StmtObj (SqlStmtId "f.srf" "obj1" "proc1" 5) ]
            -- initSchemaRelations now materializes stmt eagerly (Plan 175 Phase 1) --
            -- must run after appendSchemaObjects, not merely after initSchema.
            schRows <- initSchemaRelations conn []
            materializeLiveProc conn (DeadCodeClosureReady ()) schRows
            rows <- queryHandle conn "SELECT object, proc FROM live_proc" :: IO [(Text, Text)]
            assertBool "(obj1,proc1) present" (("obj1", "proc1") `elem` rows)

      , testCase "a stmt whose (object,proc) is in proc_dead is excluded from live_proc" $
          withHandle inMemory $ \conn -> do
            initSchema conn
            -- obj2/proc2: a function with no entry seed and no caller, so
            -- materializeDeadCodeClosure naturally computes it as dead.
            withAppenderPool conn phaseATables $ \pool ->
              appendProcedures pool
                [ ProcRow "f.srf" "obj2" "proc2" "function" 1 1 "" "" "" "" "" (Just 1) "confirmed" [] ]
            dcRows <- initDeadCodeRelations conn
            materializeDeadCodeClosure dcRows conn
            appendSchemaObjects conn [ StmtObj (SqlStmtId "f.srf" "obj2" "proc2" 9) ]
            schRows <- initSchemaRelations conn []
            materializeLiveProc conn (DeadCodeClosureReady ()) schRows
            rows <- queryHandle conn "SELECT object, proc FROM live_proc" :: IO [(Text, Text)]
            assertBool "(obj2,proc2) absent" (("obj2", "proc2") `notElem` rows)

      , testCase "a DW retrieve StmtObj (no real proc) never appears in live_proc" $
          -- Regression: a 'dw_retrieve'-kind schema_objects row has stmt_proc = NULL,
          -- which can never match proc_dead's (object, proc) rows -- if the
          -- `stmt` input relation view included it, every DW retrieve would vacuously pass the
          -- NOT EXISTS dead check and pollute live_proc with meaningless rows
          -- (found via a real --db smoke run over the openpay corpus).
          withHandle inMemory $ \conn -> do
            initSchema conn
            dcRows <- initDeadCodeRelations conn
            materializeDeadCodeClosure dcRows conn
            appendSchemaObjects conn [ StmtObj (DwRetrieveId "d.srd" "d_test") ]
            schRows <- initSchemaRelations conn []
            materializeLiveProc conn (DeadCodeClosureReady ()) schRows
            rows <- queryHandle conn "SELECT object, proc FROM live_proc" :: IO [(Text, Text)]
            assertBool "no dw_retrieve row leaks into live_proc" (null rows)
      ]

    , -- The full proc_dead-shape fixture set previously here (event-handler
      -- seeds, dead chains, override propagation, cross-object reachability,
      -- confidence-shape combinations, case-insensitive/dotted call-name
      -- matching) moved to 'DeadCodeReachabilityTest' as golden assertions --
      -- 'deadReach' is the sole implementation, so there is no second
      -- implementation left to oracle-diff against.
      testGroup "Relation filtering"
      [ testCase "speculative-confidence procedures (builtin method stubs) are excluded from proc/entry/proc_dead" $
          -- Regression: a real openpay --db run's proc_dead had 45 extra rows,
          -- all speculative-confidence stub procedures registered for PB base
          -- classes (dwobject/powerobject/window/...) -- 'queryProcInfos'
          -- already filters `confidence != 'speculative'`; the raw
          -- `proc`/`entry`/`calls` SQL views must apply the same filter or
          -- they silently disagree.
          withHandle inMemory $ \conn -> do
            initSchema conn
            withAppenderPool conn phaseATables $ \pool ->
              appendProcedures pool
                [ ProcRow "builtin" "dwobject" "Retrieve" "function" 1 1 "" "" "" "" "" Nothing "speculative" [] ]
            _ <- initDeadCodeRelations conn
            procViewRows <- queryHandle conn "SELECT object, proc FROM proc" :: IO [(Text, Text)]
            entryViewRows <- queryHandle conn "SELECT object, proc FROM entry" :: IO [(Text, Text)]
            assertBool "speculative stub excluded from proc view" (null procViewRows)
            assertBool "speculative stub excluded from entry view" (null entryViewRows)
      ]

    , testGroup "callerCounts / confidence"
      -- Previously-uncovered caller-count levels. Table-driven since all three
      -- share the same seed-fixture-then-assert-confidence-level shape
      -- (CLAUDE.md's table-driven-tests guidance). Confidence classification
      -- is an internal CTE step inside the collapsed 'materializeDeadCode'
      -- (Plan 198 Phase A) -- observed via 'dead_code.confidence', not a
      -- standalone table, so every case here seeds no 'entry' rows, making
      -- every proc unreachable/dead by construction (see
      -- 'DeadCodeReachability.materializeDeadCodeClosure') and therefore
      -- present in the final 'dead_code' output.
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

    , testGroup "materializeDeadCode"
      -- Plan 198 Phase A: the 8-table caller-count/confidence chain
      -- (has_naive_caller / has_scoped_caller / caller_count_naive /
      -- caller_count_scoped / confidence / caller_count_naive_final /
      -- caller_count_scoped_final / dead_code_rows) is gone. A single
      -- 'materializeDeadCode' call now goes straight from the four
      -- pre-existing input relations (proc_dead, proc_meta, call_ref,
      -- resolved_call_edge) to 'dead_code', with INTEGER counts throughout
      -- -- no VARCHAR round-trip.
      [ testCase "caller counts land in dead_code: naive counts every name-match, scoped only resolved edges" $
          withHandle inMemory $ \conn -> do
            initSchema conn
            withAppenderPool conn phaseATables $ \pool ->
              seedDeadCodeFixture conn pool
                [ ProcInfo "obj" "fn" "function" (Just 3) ]
                -- Two distinct unresolved callers of "fn".
                [ ("other_obj", "caller_a", "fn"), ("other_obj", "caller_b", "fn") ]
                -- One resolved call site, from a third caller. A resolved call
                -- also satisfies the naive (name-match) relation -- 'call_ref'
                -- is built from every resolved_calls row regardless of
                -- resolution status (see 'initDeadCodeRelations'' 'call_ref'
                -- reshaping) -- so naive_n counts all three callers while
                -- scoped_n counts only the one truly-resolved edge.
                [ ("other_obj", "caller_c", "obj", "fn") ]
                [] Set.empty
            dcRows <- initDeadCodeRelations conn
            materializeDeadCodeClosure dcRows conn
            materializeDeadCode conn (DeadCodeClosureReady ())
            -- dead_code's counts are real INTEGER columns now -- no TRY_CAST
            -- round-trip through an intermediate TEXT relation.
            rows <- queryHandle conn
              "SELECT caller_count_naive, caller_count_scoped \
              \FROM dead_code WHERE object = 'obj' AND proc_name = 'fn'"
              :: IO [(Int, Int)]
            rows @?= [(3, 1)]

      , testCase "overloaded procedure name: materializeDeadCode keeps the highest-cyclomatic row" $
          -- PowerBuilder overloads collapse to one (object, proc_name) pair at
          -- reachability granularity -- two ProcInfo entries sharing the same
          -- (object, name) simulate two overloads with different cyclomatic
          -- complexity. materializeDeadCode's ROW_NUMBER() tie-break must pick
          -- the highest cyclomatic deterministically (see its own doc comment
          -- in PB.Pipeline.DuckDb.Materialize).
          withHandle inMemory $ \conn -> do
            initSchema conn
            withAppenderPool conn phaseATables $ \pool ->
              seedDeadCodeFixture conn pool
                [ ProcInfo "obj" "fn" "function" (Just 3)
                , ProcInfo "obj" "fn" "function" (Just 7)
                ]
              [] [] [] Set.empty
            dcRows <- initDeadCodeRelations conn
            materializeDeadCodeClosure dcRows conn
            materializeDeadCode conn (DeadCodeClosureReady ())
            rows <- queryHandle conn
              "SELECT cyclomatic FROM dead_code WHERE object = 'obj' AND proc_name = 'fn'"
              :: IO [Only Int]
            [ c | Only c <- rows ] @?= [7]

      , testCase "overloaded procedure with one unknown cyclomatic: the known value still wins the tie-break" $
          -- Regression: ORDER BY ... DESC without NULLS LAST defaults to
          -- NULLS FIRST in DuckDB, so an overload with an unknown (Nothing)
          -- cyclomatic would sort ahead of a sibling with a real value,
          -- contradicting materializeDeadCode's documented "keeps the
          -- highest-cyclomatic row" tie-break.
          withHandle inMemory $ \conn -> do
            initSchema conn
            withAppenderPool conn phaseATables $ \pool ->
              seedDeadCodeFixture conn pool
                [ ProcInfo "obj" "fn" "function" Nothing
                , ProcInfo "obj" "fn" "function" (Just 5)
                ]
              [] [] [] Set.empty
            dcRows <- initDeadCodeRelations conn
            materializeDeadCodeClosure dcRows conn
            materializeDeadCode conn (DeadCodeClosureReady ())
            rows <- queryHandle conn
              "SELECT cyclomatic FROM dead_code WHERE object = 'obj' AND proc_name = 'fn'"
              :: IO [Only Int]
            [ c | Only c <- rows ] @?= [5]
      ]

    , -- Plan 187 §18 tier 1: 'initDeadCodeRelations' now returns the rows it
      -- fetched (as 'DeadCodeInputRows') instead of 'materializeDeadCodeClosure'
      -- re-querying the same four tables. This guards against the returned
      -- bundle silently drifting from what was actually fetched/materialized
      -- (e.g. a future edit returning stale or swapped fields) -- not against
      -- 'deadReach' correctness, which 'DeadCodeReachabilityTest' already covers.
      testGroup "initDeadCodeRelations returns fetched rows"
      [ testCase "returned DeadCodeInputRows matches independently re-querying the same tables" $
          withHandle inMemory $ \conn -> do
            initSchema conn
            withAppenderPool conn phaseATables $ \pool ->
              seedDeadCodeFixture conn pool
                [ ProcInfo "obj" "fn" "function" (Just 1) ]
                []
                [ ("obj", "fn", "callee_obj", "callee_fn") ]
                [ ("child_obj", "parent_obj") ]
                (Set.fromList ["dw_obj"])
            dcRows <- initDeadCodeRelations conn
            procsIndependent     <- queryProcedures conn
            callsIndependent     <- queryResolvedCalls conn
            ancestorsIndependent <- queryObjectAncestors conn
            dwObjsIndependent    <- queryDwObjects conn
            dcrProcs dcRows     @?= procsIndependent
            dcrCalls dcRows     @?= callsIndependent
            dcrAncestors dcRows @?= ancestorsIndependent
            dcrDwObjects dcRows @?= dwObjsIndependent
      ]

    , -- Plan 187 §18 tier 1: 'initSchemaRelations' now returns the rows it
      -- fetched (as 'SchemaInputRows') instead of 'materializeSchemaClosure'
      -- re-querying the same two tables. Same rationale as the DeadCode
      -- group above -- guards the plumbing, not 'legPriority'/'reachClosure'
      -- correctness ('SchemaClosureTest' already covers that.)
      testGroup "initSchemaRelations returns fetched rows"
      [ testCase "returned SchemaInputRows matches independently re-querying the same tables" $
          withHandle inMemory $ \conn -> do
            initSchema conn
            let colA = ColumnObj (TableRef Nothing "a") "x"
                colB = ColumnObj (TableRef Nothing "b") "y"
            appendSchemaMorphisms conn [ SchMorphism colA colB LegFk SrcDwJoin ]
            appendSchemaObjects conn [ StmtObj (SqlStmtId "f.srf" "obj" "proc" 5) ]
            schRows <- initSchemaRelations conn []
            morphismsIndependent <- querySchemaMorphismRows conn
            objectsIndependent   <- querySchemaObjects conn
            sirMorphisms schRows @?= morphismsIndependent
            sirObjects schRows   @?= objectsIndependent
      ]

    , -- Plan 175 Phase 2: direct unit tests of 'initDeadCodeRelations''s pure
      -- reshaping functions -- no 'Handle'\/external engine needed, mirroring
      -- 'SchemaClosureTest''s Phase 1 precedent.
      testGroup "MaterializedRelations"
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

  , -- Plan 201 Phase 5a: 'typeCoverageStats' is the token-level coverage
    -- diagnostic, corrected to use 'identifier_tokens' (the raw lexed
    -- token stream) as the denominator instead of rows already present in
    -- 'resolved_var_refs'/'resolved_calls' -- an identifier that never
    -- became a row (e.g. an unparsed @::@ chain) is invisible to a
    -- row-based percentage, which over-reports coverage.
    testGroup "TypeCoverageStats"
    [ testCase "zero identifier_tokens rows: totals are 0, no crash" $
        withHandle inMemory $ \conn -> do
          initSchema conn
          stats <- typeCoverageStats conn
          stats @?= TypeCoverageStats 0 0 0 0 0 0

    , testCase "a token with a matching resolved_var_refs span counts as resolved" $
        withHandle inMemory $ \conn -> do
          initSchema conn
          withAppenderPool conn phaseATables $ \pool -> do
            appendIdentifierTokens pool
              [IdentifierTokenRow "f.srw" "li_count" "TkIdent" (SourceSpan 5 3 5 11)]
            appendVarRefs pool
              [ResolvedVarRef "f.srw" "w_test" "of_save" (Just 5) "li_count" "read"
                              Nothing "local" "high" (Just (SourceSpan 5 3 5 11)) (Just "integer")]
          stats <- typeCoverageStats conn
          tcsTotalIdentifierTokens stats @?= 1
          tcsResolvedIdentifierTokens stats @?= 1

    , testCase "a token with a matching resolved_calls span counts as resolved" $
        withHandle inMemory $ \conn -> do
          initSchema conn
          withAppenderPool conn phaseATables $ \pool ->
            appendIdentifierTokens pool
              [IdentifierTokenRow "f.srw" "Reset" "TkIdent" (SourceSpan 8 10 8 15)]
          appendResolvedCalls conn
            [ResolvedCall "f.srw" "dw_1" "of_save" "Reset" "method" (Just 8)
                          Nothing Nothing "builtin" "high" (Just (SourceSpan 8 10 8 15))]
          stats <- typeCoverageStats conn
          tcsTotalIdentifierTokens stats @?= 1
          tcsResolvedIdentifierTokens stats @?= 1

    , testCase "a token that never became a row (Issue-1-shaped gap) is unresolved" $
        withHandle inMemory $ \conn -> do
          initSchema conn
          withAppenderPool conn phaseATables $ \pool ->
            appendIdentifierTokens pool
              [ IdentifierTokenRow "f.srw" "super"  "TkIdent"   (SourceSpan 1 1 1 6)
              , IdentifierTokenRow "f.srw" "create" "TkOtherKw" (SourceSpan 1 8 1 14)
              ]
          -- No resolved_var_refs/resolved_calls rows seeded: both tokens
          -- fell into BsRaw before Phase 1 lands, exactly Issue 1's gap.
          stats <- typeCoverageStats conn
          tcsTotalIdentifierTokens stats @?= 2
          tcsResolvedIdentifierTokens stats @?= 0

    , testCase "duplicate-span identifier_tokens rows each count toward the denominator" $
        withHandle inMemory $ \conn -> do
          initSchema conn
          withAppenderPool conn phaseATables $ \pool -> do
            appendIdentifierTokens pool
              [ IdentifierTokenRow "f.srw" "li_x" "TkIdent" (SourceSpan 2 1 2 5)
              , IdentifierTokenRow "f.srw" "li_x" "TkIdent" (SourceSpan 2 1 2 5)
              ]
            appendVarRefs pool
              [ResolvedVarRef "f.srw" "w_test" "of_save" (Just 2) "li_x" "read"
                              Nothing "local" "high" (Just (SourceSpan 2 1 2 5)) Nothing]
          stats <- typeCoverageStats conn
          tcsTotalIdentifierTokens stats @?= 2
          tcsResolvedIdentifierTokens stats @?= 2

    , testCase "__stdlib__-prefixed rows are excluded from every count" $
        withHandle inMemory $ \conn -> do
          initSchema conn
          withAppenderPool conn phaseATables $ \pool -> do
            appendIdentifierTokens pool
              [ IdentifierTokenRow "__stdlib__/base.sru" "li_x" "TkIdent" (SourceSpan 1 1 1 5)
              , IdentifierTokenRow "corpus/f.srw"        "li_y" "TkIdent" (SourceSpan 1 1 1 5)
              ]
            appendVarRefs pool
              [ ResolvedVarRef "__stdlib__/base.sru" "w_base" "of_x" (Just 1) "li_x" "read"
                               Nothing "local" "high" (Just (SourceSpan 1 1 1 5)) Nothing
              , ResolvedVarRef "corpus/f.srw" "w_test" "of_save" (Just 1) "li_y" "read"
                               Nothing "local" "high" (Just (SourceSpan 1 1 1 5)) Nothing
              ]
          stats <- typeCoverageStats conn
          tcsTotalIdentifierTokens stats @?= 1
          tcsResolvedIdentifierTokens stats @?= 1
          tcsVarRefTotal stats @?= 1
          tcsVarRefResolved stats @?= 1
    ]
  ]

-- | Assert 'materializeDeadCode'\'s confidence classification (a CTE step
-- internal to that materializer, not a standalone table -- see Plan 198
-- Phase A) puts the given (object, proc) at the expected level. The
-- classification itself reads only @proc_meta@\/@call_ref@\/
-- @resolved_call_edge@, but observing it requires the proc to actually
-- appear in @dead_code@, which requires @proc_dead@ membership -- so no
-- @entry@ rows are seeded here, making every proc unreachable/dead by
-- construction.
assertConfidence
  :: String
  -> [ProcInfo] -> [(Text, Text, Text)] -> [(Text, Text, Text, Text)]
  -> (Text, Text) -> Text
  -> TestTree
assertConfidence name procs calls resolved (obj, proc) expectedLevel =
  testCase name $ withHandle inMemory $ \conn -> do
    initSchema conn
    withAppenderPool conn phaseATables $ \pool -> do
      seedDeadCodeFixture conn pool procs calls resolved [] Set.empty
    dcRows <- initDeadCodeRelations conn
    -- No 'entry' rows are seeded above, so every proc is unreachable and
    -- therefore dead by construction -- 'confidence' is no longer a
    -- standalone table (Plan 198 Phase A collapsed it into 'dead_code'),
    -- so it's observed on the one dead_code row this produces.
    materializeDeadCodeClosure dcRows conn
    materializeDeadCode conn (DeadCodeClosureReady ())
    rows <- queryHandle conn
              (Query $ "SELECT confidence FROM dead_code WHERE object = '" <> obj <> "' AND proc_name = '" <> proc <> "'") :: IO [Only Text]
    [ lvl | Only lvl <- rows ] @?= [expectedLevel]
