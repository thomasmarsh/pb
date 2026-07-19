module SchemaAlgebraTest (tests) where

-- | Golden regression suite for 'PB.Analysis.SchemaAlgebra' (hand-rolled
-- Haskell closures over the interned leg relation — NOT Souffle's
-- 'PB.Analysis.Rules.Schema.legRules'/'reachesRules'/'cosliceRules', which
-- are deleted as of the Plan 182 schema-coslice cutover, §17). Each
-- fixture's expected output was cross-checked against the (now-deleted)
-- Souffle oracle during the cutover — see doc/plan/182-algebraic-analysis.md
-- §17 for the oracle-diff history. No Souffle round-trip runs here any more:
-- the algebraic closures are the sole implementation, so there is nothing
-- left to diff against.
import PB.Prelude
import PB.Analysis.SchemaAlgebra
  ( legAlgebraic, reachesAlgebraic, cosliceAlgebraic )
import PB.Analysis.SchemaCategory
  ( StmtId (..), SchObject (..), SchMorphism (..)
  , SchemaInputs (..), CatFkRow (..)
  , buildSchema, schObjectKey, sgLegs, sgObjects
  )
import PB.Pipeline.DuckDb (renderLegKind)
import PB.Pipeline.SqlParse (TableRef (..))

import qualified Data.Set as Set
import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=), assertBool)

emptyInputs :: SchemaInputs
emptyInputs = SchemaInputs [] [] [] [] [] [] [] [] Nothing

col :: Text -> Text -> SchObject
col t c = ColumnObj (TableRef Nothing t) c

stmt :: Text -> Text -> Text -> Int -> SchObject
stmt f o p l = StmtObj (SqlStmtId f o p l)

legRowsOf :: [SchMorphism] -> [[Text]]
legRowsOf ms =
  [ [schObjectKey (legFrom m), schObjectKey (legTo m), renderLegKind (legKind m)] | m <- ms ]

tests :: TestTree
tests = testGroup "SchemaAlgebra (closures, production)"
  [ testGroup "legAlgebraic (priority cascade)"
    [ testCase "writes beats retrieve regardless of insertion order" $
        let colA = col "a" "x"
            rows = [ [schObjectKey colA, schObjectKey colA, "retrieve"]
                   , [schObjectKey colA, schObjectKey colA, "writes"] ]
        in legAlgebraic rows @?= [[schObjectKey colA, schObjectKey colA, "writes"]]

    , testCase "0-hop self-referential collision resolves the same tie-break" $
        let colA = col "a" "x"
            rows = [ [schObjectKey colA, schObjectKey colA, "retrieve"]
                   , [schObjectKey colA, schObjectKey colA, "writes"] ]
        in legAlgebraic rows @?= [[schObjectKey colA, schObjectKey colA, "writes"]]
    ]

  , testGroup "reachesAlgebraic (forward closure)"
    [ testCase "two-hop chain: reaches contains both hops and the transitive pair" $
        let colA = col "a" "x"; colB = col "b" "y"; s = stmt "f.srf" "obj" "proc" 5
            leg = [ [schObjectKey colA, schObjectKey s, "reads"]
                  , [schObjectKey s, schObjectKey colB, "writes"] ]
            got = Set.fromList (reachesAlgebraic leg)
        in do assertBool "colA -> stmt present"
                 (Set.member [schObjectKey colA, schObjectKey s] got)
              assertBool "stmt -> colB present"
                 (Set.member [schObjectKey s, schObjectKey colB] got)
              assertBool "colA -> colB present (transitive)"
                 (Set.member [schObjectKey colA, schObjectKey colB] got)

    , testCase "cyclic 2-node graph saturates and terminates (all 4 ordered pairs, no more)" $
        let colA = col "a" "x"; colB = col "b" "y"
            leg = [ [schObjectKey colA, schObjectKey colB, "fk"]
                  , [schObjectKey colB, schObjectKey colA, "fk"] ]
            got = Set.fromList (reachesAlgebraic leg)
        in got @?= Set.fromList
             [ [schObjectKey colA, schObjectKey colA], [schObjectKey colA, schObjectKey colB]
             , [schObjectKey colB, schObjectKey colA], [schObjectKey colB, schObjectKey colB] ]
    ]

  , testGroup "cosliceAlgebraic (multi-witness shortest path)"
    [ testCase "forward+backward path_leg reaches both StmtObj targets, filters column intermediates" $
        let colA = col "a" "x"; colX = col "x" "w"
            stmtS = stmt "f.srf" "objS" "procS" 5
            stmtT = stmt "f.srf" "objT" "procT" 9
            colB = col "b" "y"; colC = col "c" "z"
            leg = [ [schObjectKey colA, schObjectKey stmtS, "reads"]
                  , [schObjectKey stmtS, schObjectKey colB, "writes"]
                  , [schObjectKey colB, schObjectKey colC, "fk"]
                  , [schObjectKey colC, schObjectKey stmtT, "reads"]
                  , [schObjectKey colX, schObjectKey colA, "writes"] ]
            seeds = [schObjectKey colA]
            (fwd, back) = cosliceAlgebraic seeds leg
            stmtKeys = Set.fromList [schObjectKey stmtS, schObjectKey stmtT]
            fwdTargets = Set.fromList [ t | [_, t, _, _, _, _] <- fwd ]
            backTargets = Set.fromList [ t | [_, t, _, _, _, _] <- back ]
        in do assertBool "forward reaches both StmtObj targets"
                 (stmtKeys `Set.isSubsetOf` fwdTargets)
              assertBool "forward StmtObj targets exactly {stmtS, stmtT}"
                 (Set.intersection fwdTargets stmtKeys == stmtKeys)
              assertBool "backward StmtObj targets empty (only column colX)"
                 (Set.intersection backTargets stmtKeys == Set.empty)

    , testCase "FK cycle not through the seed: minimal, unique distances (path_leg_fwd content)" $
        let colA = col "a" "x"; colB = col "b" "y"; colC = col "c" "z"
            leg = [ [schObjectKey colA, schObjectKey colB, "fk"]
                  , [schObjectKey colB, schObjectKey colC, "fk"]
                  , [schObjectKey colC, schObjectKey colB, "fk"] ]
            seeds = [schObjectKey colA]
            (fwd, _back) = cosliceAlgebraic seeds leg
            expected = Set.fromList
              [ [schObjectKey colA, schObjectKey colB, "0", schObjectKey colA, schObjectKey colB, "fk"]
              , [schObjectKey colA, schObjectKey colC, "1", schObjectKey colB, schObjectKey colC, "fk"]
              , [schObjectKey colA, schObjectKey colC, "0", schObjectKey colA, schObjectKey colB, "fk"]
              ]
        in Set.fromList fwd @?= expected

    , testCase "diamond: path_leg emits <= object-count rows (no exponential blowup)" $
        let n = 15 :: Int
            tbl (i :: Int) s = "t" <> T.pack (show i) <> s
            colName = "id"
            seedKey = "col:" <> tbl 0 "" <> "." <> colName
            layerFks i =
              [ CatFkRow Nothing (tbl i "") colName Nothing (tbl i "a") colName
              , CatFkRow Nothing (tbl i "") colName Nothing (tbl i "b") colName
              , CatFkRow Nothing (tbl i "a") colName Nothing (tbl (i+1) "") colName
              , CatFkRow Nothing (tbl i "b") colName Nothing (tbl (i+1) "") colName
              ]
            inp = emptyInputs { inCatalogFks = concatMap layerFks [0 .. n-1] }
            sch = buildSchema inp
            leg = legRowsOf (sgLegs sch)
            objCount = Set.size (sgObjects sch)
            (fwd, _back) = cosliceAlgebraic [seedKey] leg
            targetCount = Set.size (Set.fromList [ t | [_, t, _, _, _, _] <- fwd ])
        in assertBool ("target count " <> show targetCount <> " should stay <= object count " <> show objCount)
                      (targetCount <= objCount)
    ]
  ]
