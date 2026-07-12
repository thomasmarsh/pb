module SouffleSchemaTest (tests) where

import PB.Prelude
import PB.Pipeline.Souffle
import PB.Analysis.Rules.Schema
import PB.Pipeline.DuckDb
import PB.Analysis.SchemaCategory
  ( StmtId (..), SchObject (..), LegKind (..), LegSource (..), SchMorphism (..)
  , SchemaInputs (..), SqlColRow (..), SchGraph (..)
  , buildSchema, blastRadius, schObjectKey, spTo
  )
import PB.Pipeline.SqlParse (TableRef (..))

import qualified Data.Set  as Set

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
  ]
