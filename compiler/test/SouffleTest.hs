module SouffleTest (tests) where

import PB.Prelude
import PB.Pipeline.Souffle
import PB.Pipeline.DuckDb
import PB.Analysis.SchemaCategory
  ( StmtId (..), SchObject (..), LegKind (..), LegSource (..), SchMorphism (..)
  , SchemaInputs (..), SqlColRow (..), SchGraph (..)
  , buildSchema, blastRadius, schObjectKey, spTo
  )
import PB.Analysis.DeadCode (DeadProcedure (..))
import PB.Pipeline.SqlParse (TableRef (..))

import qualified Data.Set  as Set

import Database.DuckDB.Simple (query, query_, Only (..))
import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

emptyInputs :: SchemaInputs
emptyInputs = SchemaInputs [] [] [] [] [] [] [] [] Nothing

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
    [ testCase "a stmt whose (object,proc) is not in dead_code appears in live_proc" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          initEdbViews conn
          appendSchemaObjects conn [ StmtObj (SqlStmtId "f.srf" "obj1" "proc1" 5) ]
          runRuleSet conn liveProcRules
          rows <- query_ conn "SELECT object, proc FROM live_proc" :: IO [(Text, Text)]
          assertBool "(obj1,proc1) present" (("obj1", "proc1") `elem` rows)

    , testCase "a stmt whose (object,proc) is in dead_code is excluded from live_proc" $
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          initEdbViews conn
          appendSchemaObjects conn [ StmtObj (SqlStmtId "f.srf" "obj2" "proc2" 9) ]
          appendDeadCode conn [ DeadProcedure "obj2" "proc2" "function" (Just 1) "high" 0 0 ]
          runRuleSet conn liveProcRules
          rows <- query_ conn "SELECT object, proc FROM live_proc" :: IO [(Text, Text)]
          assertBool "(obj2,proc2) absent" (("obj2", "proc2") `notElem` rows)

    , testCase "a DW retrieve StmtObj (no real proc) never appears in live_proc" $
        -- Regression: a 'dw_retrieve'-kind schema_objects row has stmt_proc = NULL,
        -- which can never match dead_code's (object, proc_name) rows -- if the
        -- `stmt` EDB view included it, every DW retrieve would vacuously pass the
        -- NOT EXISTS dead check and pollute live_proc with meaningless rows
        -- (found via a real --db smoke run over the openpay corpus).
        withWriteConn ":memory:" $ \conn -> do
          initSchema conn
          initEdbViews conn
          appendSchemaObjects conn [ StmtObj (DwRetrieveId "d.srd" "d_test") ]
          runRuleSet conn liveProcRules
          rows <- query_ conn "SELECT object, proc FROM live_proc" :: IO [(Text, Text)]
          assertBool "no dw_retrieve row leaks into live_proc" (null rows)
    ]
  ]
