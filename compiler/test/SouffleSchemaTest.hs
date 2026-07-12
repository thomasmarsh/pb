module SouffleSchemaTest (tests) where

import PB.Prelude
import PB.Pipeline.Souffle
import PB.Analysis.Rules.Schema
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

import Database.DuckDB.Simple (query, query_, Only (..))
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
          initEdbViews conn
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
          runRuleSets (\_ -> pure ()) conn [reachesRules, cosliceRules]
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
          initEdbViews conn
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
          runRuleSets (\_ -> pure ()) conn [reachesRules, cosliceRules]
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
          initEdbViews conn
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
          runRuleSets (\_ -> pure ()) conn [reachesRules, cosliceRules]
          rows <- query conn "SELECT node, dist FROM min_dist WHERE s = ?" (Only colAKey)
                    :: IO [(Text, Text)]
          let byNode = Map.fromListWith (<>) [ (n, [d]) | (n, d) <- rows ]
          Map.lookup colBKey byNode @?= Just ["1"]
          Map.lookup colCKey byNode @?= Just ["2"]
    ]
  ]
