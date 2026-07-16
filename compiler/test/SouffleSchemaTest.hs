module SouffleSchemaTest (tests) where

import PB.Prelude
import PB.Pipeline.Souffle
import PB.Analysis.Rules.Schema
  ( initEdbViews, reachesRules, cosliceRules, legRules, legSourceRows, stmtRows, seedRows
  , impliedFkRules, riskRules, joinLegRows, fkRows
  )
import PB.Pipeline.DuckDb
import PB.Analysis.SchemaCategory
  ( StmtId (..), SchObject (..), LegKind (..), LegSource (..), SchMorphism (..)
  , SchemaInputs (..), SqlColRow (..), SchGraph (..), CatFkRow (..)
  , buildSchema, schObjectKey
  )
import PB.Pipeline.SqlParse (TableRef (..))

import qualified Data.Map.Strict as Map
import qualified Data.Set  as Set
import qualified Data.Text as T

import Database.DuckDB.Simple (query, query_, execute_, Query (..), Only (..))
import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

emptyInputs :: SchemaInputs
emptyInputs = SchemaInputs [] [] [] [] [] [] [] [] Nothing

-- | 'PB.Analysis.Rules.Schema.reachesRules' parity tests -- Plan 166 Stage 9
-- split out of the former @SouffleTest.hs@ (which mixed these with the
-- dead-code rule sets; see @SouffleDeadCodeTest.hs@ for those). Same
-- behavioral assertions as the old DuckDB-native 'PB.Pipeline.Datalog' test
-- suite -- 'reachesRules' is the same values, now materialized via the
-- Souffle CLI instead of generated SQL.
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

  , -- Plan 171a: 'legRules' moves the writes-vs-retrieve tie-break for
    -- @leg@ out of 'initEdbViews' SQL (a ROW_NUMBER/CASE pair, a house-rule
    -- violation per compiler/CLAUDE.md's Datalog Rule Placement Discipline)
    -- into rule specialization (leg_raw's priority column) + choice-domain
    -- (leg itself) -- the same mechanism 'cosliceRules' already uses for
    -- min_dist/min_dist_back. Off-seed-cycle coverage for this shape lives
    -- in the existing "FK cycle not through the seed" cosliceRules test
    -- below, which exercises Datalog-derived @leg@ end-to-end -- @leg@ has
    -- no fixpoint of its own, so an isolated off-seed-cycle fixture isn't
    -- structurally meaningful for this rule set alone.
    testGroup "legRules"
    [ testCase "duplicate-key collision: writes beats retrieve regardless of insertion order" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          let colA = ColumnObj (TableRef Nothing "a") "x"
              colB = ColumnObj (TableRef Nothing "b") "y"
          -- retrieve inserted first -- a naive "first tuple wins" derivation
          -- would pick retrieve; the priority tie-break must still pick writes.
          appendSchemaMorphisms conn
            [ SchMorphism colA colB LegRetrieve SrcDwRetrieve
            , SchMorphism colA colB LegWrites   SrcSqlText
            ]
          -- initEdbViews now materializes leg_source eagerly (Plan 175 Phase
          -- 1) -- must run after the data it reads is populated, not merely
          -- after initSchema creates the empty tables (a lazily-evaluated
          -- CREATE VIEW tolerated the old call order; a plain table does not).
          initEdbViews conn
          runRuleSet conn legRules
          rows <- query_ conn "SELECT x, y, leg_kind FROM leg" :: IO [(Text, Text, Text)]
          rows @?= [(schObjectKey colA, schObjectKey colB, "writes")]

    , testCase "0-hop self-referential collision resolves the same tie-break" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          let colA = ColumnObj (TableRef Nothing "a") "x"
          appendSchemaMorphisms conn
            [ SchMorphism colA colA LegRetrieve SrcDwRetrieve
            , SchMorphism colA colA LegWrites   SrcSqlText
            ]
          initEdbViews conn
          runRuleSet conn legRules
          rows <- query_ conn "SELECT x, y, leg_kind FROM leg" :: IO [(Text, Text, Text)]
          rows @?= [(schObjectKey colA, schObjectKey colA, "writes")]
    ]

  , testGroup "reachesRules"
    [ testCase "two-hop chain: reaches contains both hops and the transitive pair" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
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
          initEdbViews conn
          runRuleSets (\_ -> pure ()) conn [legRules, reachesRules]
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
          let colA = ColumnObj (TableRef Nothing "a") "x"
              colB = ColumnObj (TableRef Nothing "b") "y"
              colAKey = schObjectKey colA
              colBKey = schObjectKey colB
          appendSchemaMorphisms conn
            [ SchMorphism colA colB LegFk SrcDdlFk
            , SchMorphism colB colA LegFk SrcDdlFk
            ]
          initEdbViews conn
          runRuleSets (\_ -> pure ()) conn [legRules, reachesRules]
          rows <- query_ conn "SELECT x, y FROM reaches" :: IO [(Text, Text)]
          let got = Set.fromList rows
          got @?= Set.fromList
            [ (colAKey, colAKey), (colAKey, colBKey)
            , (colBKey, colAKey), (colBKey, colBKey)
            ]

    ]

  , -- Plan 161 Phase 2c: cosliceRules' path_leg_fwd/path_leg_back reconstruct
    -- the leg-chain witnesses that materializeDecompositionCoslice projects
    -- into decomposition_coslice. cosliceRules consumes reaches as EDB, so
    -- both rule sets run via runRuleSets (which orders them by that
    -- dependency). The fixed expected values below were validated against the
    -- Haskell columnCoslice oracle during the Phase 2c cutover (the oracle
    -- itself was deleted once parity was proven — see git history).
    testGroup "cosliceRules"
    [ testCase "forward+backward path_leg reaches both StmtObj targets, filters column intermediates" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          -- col_A --reads--> stmt_S --writes--> col_B --fk--> col_C --reads--> stmt_T
          -- col_X --writes--> col_A  (backward writer; a column, not a StmtObj)
          let colA = ColumnObj (TableRef Nothing "a") "x"
              colX = ColumnObj (TableRef Nothing "x") "w"
              stmtS = SqlStmtId "f.srf" "objS" "procS" 5
              stmtT = SqlStmtId "f.srf" "objT" "procT" 9
              inp = emptyInputs
                { inSqlColumns =
                    [ SqlColRow stmtS Nothing (Just "a") "x" False
                    , SqlColRow stmtS Nothing (Just "b") "y" True
                    , SqlColRow stmtT Nothing (Just "c") "z" False
                    ]
                , inCatalogFks = [ CatFkRow Nothing "b" "y" Nothing "c" "z" ]
                }
              sch = buildSchema inp
              extraLeg = SchMorphism colX colA LegWrites SrcSqlText
              allLegs = sgLegs sch <> [extraLeg]
              allObjs = Set.insert colX (sgObjects sch)
          appendSchemaObjects conn (Set.toList allObjs)
          appendSchemaMorphisms conn allLegs
          initEdbViews conn
          runRuleSets (\_ -> pure ()) conn [legRules, reachesRules, cosliceRules]
          -- StmtObj targets reached from colA: stmtS (forward, direct) and
          -- stmtT (forward, via col_B->col_C FK chain). col_X (backward writer)
          -- is a column, filtered out by the StmtObj contract.
          let colAKey = schObjectKey colA
              stmtFilter = "SELECT DISTINCT target FROM path_leg_fwd WHERE s = ? \
                           \INTERSECT SELECT object_key FROM schema_objects WHERE kind IN ('stmt','dw_retrieve')"
              backFilter = "SELECT DISTINCT target FROM path_leg_back WHERE s = ? \
                           \INTERSECT SELECT object_key FROM schema_objects WHERE kind IN ('stmt','dw_retrieve')"
          fwdRows <- query conn stmtFilter (Only colAKey) :: IO [Only Text]
          backRows <- query conn backFilter (Only colAKey) :: IO [Only Text]
          let datalogTargets = Set.fromList [ t | Only t <- fwdRows <> backRows ]
          datalogTargets @?= Set.fromList
            [ schObjectKey (StmtObj stmtS), schObjectKey (StmtObj stmtT) ]

    , testCase "diamond: path_leg emits ≤ object-count rows (no exponential blowup)" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          -- 15 chained diamonds (the SchemaCategoryTest.hs:436 stress fixture):
          -- layerFks i = [t_i->t_ia, t_i->t_ib, t_ia->t_{i+1}, t_ib->t_{i+1}]
          let n = 15 :: Int
              tbl (i :: Int) s = "t" <> T.pack (show i) <> s
              col = "id"
              seedKey = "col:" <> tbl 0 "" <> "." <> col
              layerFks i =
                [ CatFkRow Nothing (tbl i "") col Nothing (tbl i "a") col
                , CatFkRow Nothing (tbl i "") col Nothing (tbl i "b") col
                , CatFkRow Nothing (tbl i "a") col Nothing (tbl (i+1) "") col
                , CatFkRow Nothing (tbl i "b") col Nothing (tbl (i+1) "") col
                ]
              inp = emptyInputs { inCatalogFks = concatMap layerFks [0 .. n-1] }
              sch = buildSchema inp
          appendSchemaObjects conn (Set.toList (sgObjects sch))
          appendSchemaMorphisms conn (sgLegs sch)
          initEdbViews conn
          runRuleSets (\_ -> pure ()) conn [legRules, reachesRules, cosliceRules]
          -- Parity gate: distinct targets reached from seed ≤ object count.
          -- (Matches walkPaths' "one path per reachable object" guarantee.)
          fwdTargets <- query conn "SELECT COUNT(DISTINCT target) FROM path_leg_fwd WHERE s = ?" (Only seedKey) :: IO [Only Int]
          let objCount = Set.size (sgObjects sch)
              targetCount = case fwdTargets of (Only c : _) -> c; [] -> 0
          assertBool ("target count " <> show targetCount <> " should stay <= object count " <> show objCount)
                     (targetCount <= objCount)

    , -- Regression for the real-corpus hang found post-Phase-2c: an FK cycle
      -- among nodes OTHER than the seed (col_B <-> col_C, neither equal to
      -- the seed col_A) used to make min_dist derive ever-larger distances
      -- for col_B/col_C forever -- the `n != s` guard only blocks the SEED
      -- from being revisited, not other cycle members. If this test hangs,
      -- the choice-domain fix (rsChoiceDomains on minDistRel/minDistBackRel
      -- in cosliceRules) has regressed. Asserts both termination (the test
      -- completes at all) and correctness (each node's distance is unique
      -- and minimal, not just "some" value from an unbounded cycle walk).
      testCase "FK cycle not through the seed terminates with minimal, unique distances" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          let colA = ColumnObj (TableRef Nothing "a") "x"
              colB = ColumnObj (TableRef Nothing "b") "y"
              colC = ColumnObj (TableRef Nothing "c") "z"
              colAKey = schObjectKey colA
              colBKey = schObjectKey colB
              colCKey = schObjectKey colC
          appendSchemaObjects conn [colA, colB, colC]
          appendSchemaMorphisms conn
            [ SchMorphism colA colB LegFk SrcDdlFk
            , SchMorphism colB colC LegFk SrcDdlFk
            , SchMorphism colC colB LegFk SrcDdlFk
            ]
          initEdbViews conn
          runRuleSets (\_ -> pure ()) conn [legRules, reachesRules, cosliceRules]
          rows <- query conn "SELECT node, dist FROM min_dist WHERE s = ?" (Only colAKey)
                    :: IO [(Text, Text)]
          let byNode = Map.fromListWith (<>) [ (n, [d]) | (n, d) <- rows ]
          Map.lookup colBKey byNode @?= Just ["1"]
          Map.lookup colCKey byNode @?= Just ["2"]
    ]

  , -- Plan 161 Phase 3a: implied_fk_pairs(X, Y) :- join_leg(X, Y), !fk(X, Y),
    -- !fk(Y, X). join_leg/fk are pure EDB (initEdbViews), so this ruleset
    -- runs alone -- no dependency on legRules/reachesRules.
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

  , -- Plan 161 Phase 3a: risk_count(X, N) aggregates the EXISTING reaches
    -- relation's downstream footprint -- see riskRules' own doc comment for
    -- why this is not a second union-with-implied_fk traversal.
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
          runRuleSets (\_ -> pure ()) conn [legRules, reachesRules, riskRules]
          rows <- query_ conn "SELECT x, n FROM risk_count" :: IO [(Text, Text)]
          let byNode = Map.fromList rows
          Map.lookup (schObjectKey colA) byNode @?= Just "2"
          Map.lookup (schObjectKey colB) byNode @?= Just "1"
          Map.lookup (schObjectKey colC) byNode @?= Nothing

    , -- Mirrors reachesRules' own cyclic 2-node saturation test: risk_count
      -- must terminate with a stable, finite count on a cyclic graph, not
      -- just on a DAG.
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
          runRuleSets (\_ -> pure ()) conn [legRules, reachesRules, riskRules]
          rows <- query_ conn "SELECT x, n FROM risk_count" :: IO [(Text, Text)]
          let byNode = Map.fromList rows
          Map.lookup (schObjectKey colA) byNode @?= Just "2"
          Map.lookup (schObjectKey colB) byNode @?= Just "2"
    ]
  ]
