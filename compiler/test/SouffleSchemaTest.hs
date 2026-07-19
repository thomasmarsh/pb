module SouffleSchemaTest (tests) where

import PB.Prelude
import PB.Pipeline.Souffle
import PB.Analysis.Rules.Schema
  ( initEdbViews, legSourceRows, stmtRows, seedRows
  , impliedFkRules, riskRules, joinLegRows, fkRows
  )
import PB.Analysis.SchemaAlgebra qualified as SchemaAlgebra
import PB.Pipeline.DuckDb
import PB.Analysis.SchemaCategory
  ( StmtId (..), SchObject (..), LegKind (..), LegSource (..), SchMorphism (..)
  , CatFkRow (..), schObjectKey
  )
import PB.Pipeline.SqlParse (TableRef (..))

import qualified Data.Map.Strict as Map

import Database.DuckDB.Simple (query_, execute_, Query (..))
import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

-- | Plan 182 de-oracle: the schema coslice's three Souffle rule sets
-- ('legRules' / 'reachesRules' / 'cosliceRules') were replaced by the
-- hand-rolled algebraic closure in "PB.Analysis.SchemaAlgebra"
-- ('legAlgebraic' / 'reachesAlgebraic' / 'cosliceAlgebraic'), materialized
-- into the same DuckDB tables by 'SchemaAlgebra.materializeSchemaClosure'.
-- Their behavioral parity was proven by 'SchemaCorpusBench' against the
-- real corpus before deletion (see doc/plan/182-algebraic-analysis.md §17),
-- and the unit-level assertions now live in "SchemaAlgebraTest". This file
-- keeps only the Souffle-resident rule sets ('impliedFkRules', 'riskRules')
-- plus the pure-Haskell EDB reshaping checks ('EdbReshaping') — and one
-- integration test that the algebraic 'reaches' table feeds 'riskRules'.
tests :: TestTree
tests = testGroup "Souffle.Schema"

  [ -- Plan 175 Phase 1 pilot: 'legSourceRows'/'stmtRows'/'seedRows' are the
    -- pure Haskell functions that replaced 'initEdbViews''s @CREATE VIEW@
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

    , -- Plan 161 Phase 3a: 'joinLegRows'/'fkRows' feed 'impliedFkRules'.
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

  , -- Plan 161 Phase 3a: implied_fk_pairs(X, Y) :- join_leg(X, Y), !fk(X, Y),
    -- !fk(Y, X). join_leg/fk are pure EDB (initEdbViews), so this ruleset
    -- runs alone -- no dependency on the deleted legRules/reachesRules.
    testGroup "impliedFkRules"
    [ testCase "a DW-join edge with no declared FK in either direction is reported" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          let colA = ColumnObj (TableRef Nothing "a") "x"
              colB = ColumnObj (TableRef Nothing "b") "y"
          appendSchemaMorphisms conn [ SchMorphism colA colB LegFk SrcDwJoin ]
          initEdbViews conn
          runRuleSet conn impliedFkRules
          rows <- query_ conn "SELECT x, y FROM implied_fk_pairs" :: IO [(Text, Text)]
          rows @?= [(schObjectKey colA, schObjectKey colB)]

    , testCase "a DW-join edge matching a declared FK in the SAME direction is not reported" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          let colA = ColumnObj (TableRef Nothing "a") "x"
              colB = ColumnObj (TableRef Nothing "b") "y"
          appendSchemaMorphisms conn [ SchMorphism colA colB LegFk SrcDwJoin ]
          _ <- execute_ conn (Query "INSERT INTO catalog_fks VALUES ('c1', NULL, 'a', 'x', NULL, 'b', 'y', 0)")
          initEdbViews conn
          runRuleSet conn impliedFkRules
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
          initEdbViews conn
          runRuleSet conn impliedFkRules
          rows <- query_ conn "SELECT x, y FROM implied_fk_pairs" :: IO [(Text, Text)]
          rows @?= []

    , testCase "a declared DDL FK with no DW join is not spuriously reported" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          _ <- execute_ conn (Query "INSERT INTO catalog_fks VALUES ('c1', NULL, 'a', 'x', NULL, 'b', 'y', 0)")
          initEdbViews conn
          runRuleSet conn impliedFkRules
          rows <- query_ conn "SELECT x, y FROM implied_fk_pairs" :: IO [(Text, Text)]
          rows @?= []
    ]

  , -- Plan 161 Phase 3a + Plan 182 de-oracle: risk_count(X, N) aggregates the
    -- downstream footprint over the 'reaches' relation. 'reaches' is no longer
    -- a Souffle IDB -- it is now an algebraic EDB table materialized by
    -- 'SchemaAlgebra.materializeSchemaClosure' (which also writes
    -- path_leg_fwd/path_leg_back). This group is the integration gate that the
    -- algebraic closure feeds the still-Souffle 'riskRules' correctly.
    testGroup "riskRules"
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
          initEdbViews conn
          SchemaAlgebra.materializeSchemaClosure conn
          runRuleSet conn riskRules
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
          initEdbViews conn
          SchemaAlgebra.materializeSchemaClosure conn
          runRuleSet conn riskRules
          rows <- query_ conn "SELECT x, n FROM risk_count" :: IO [(Text, Text)]
          let byNode = Map.fromList rows
          Map.lookup (schObjectKey colA) byNode @?= Just "2"
          Map.lookup (schObjectKey colB) byNode @?= Just "2"
    ]
  ]
