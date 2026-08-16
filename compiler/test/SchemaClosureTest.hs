module SchemaClosureTest (tests) where

-- | Golden regression suite for 'PB.Analysis.SchemaClosure' (hand-rolled
-- Haskell closures over the interned leg relation — not an all-pairs closure). Each
-- fixture's expected output is hand-verified; the algebraic closures are the
-- sole implementation, so the assertions below are the regression contract.
import PB.Prelude
import PB.Analysis.SchemaClosure
  ( legPriority, reachClosure, cosliceClosure )
import PB.Analysis.SchemaCategory
  ( StmtId (..), SchObject (..), SchMorphism (..)
  , SchemaInputs (..), CatFkRow (..)
  , buildSchema, schObjectKey, sgLegs, sgObjects
  )
import PB.Pipeline.DuckDb.PhaseB.Append (renderLegKind)
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
tests = testGroup "SchemaClosure (closures, production)"
  [ testGroup "legPriority (priority cascade)"
    [ testCase "writes beats retrieve regardless of insertion order" $
        let colA = col "a" "x"
            rows = [ [schObjectKey colA, schObjectKey colA, "retrieve"]
                   , [schObjectKey colA, schObjectKey colA, "writes"] ]
        in legPriority rows @?= [[schObjectKey colA, schObjectKey colA, "writes"]]

    , testCase "0-hop self-referential collision resolves the same tie-break" $
        let colA = col "a" "x"
            rows = [ [schObjectKey colA, schObjectKey colA, "retrieve"]
                   , [schObjectKey colA, schObjectKey colA, "writes"] ]
        in legPriority rows @?= [[schObjectKey colA, schObjectKey colA, "writes"]]
    ]

  , testGroup "reachClosure (forward closure)"
    [ testCase "two-hop chain: reaches contains both hops and the transitive pair" $
        let colA = col "a" "x"; colB = col "b" "y"; s = stmt "f.srf" "obj" "proc" 5
            leg = [ [schObjectKey colA, schObjectKey s, "reads"]
                  , [schObjectKey s, schObjectKey colB, "writes"] ]
            got = Set.fromList (reachClosure leg)
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
            got = Set.fromList (reachClosure leg)
        in got @?= Set.fromList
             [ [schObjectKey colA, schObjectKey colA], [schObjectKey colA, schObjectKey colB]
             , [schObjectKey colB, schObjectKey colA], [schObjectKey colB, schObjectKey colB] ]
    ]

  , testGroup "cosliceClosure (multi-witness shortest path)"
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
            (fwd, back) = cosliceClosure seeds leg
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
            (fwd, _back) = cosliceClosure seeds leg
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
            (fwd, _back) = cosliceClosure [seedKey] leg
            targetCount = Set.size (Set.fromList [ t | [_, t, _, _, _, _] <- fwd ])
        in assertBool ("target count " <> show targetCount <> " should stay <= object count " <> show objCount)
                      (targetCount <= objCount)

    , testCase "one witness per (seed, target, ordinal) -- no cross-product fan-out" $
        -- The assertion the diamond case above was missing. It bounded the
        -- number of distinct *targets*, which never grew; the blow-up was in
        -- rows *per* target, because every shortest leg was emitted once for
        -- every target reachable past it. On a real corpus that reached 281
        -- rows per (seed, target) pair and 29.8M rows overall.
        --
        -- 'materializeDecompositionCoslice' keeps exactly one row per
        -- (seed, target, direction, ordinal) via ROW_NUMBER, so anything
        -- beyond one here is built only to be discarded.
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
            leg = legRowsOf (sgLegs (buildSchema inp))
            (fwd, back) = cosliceClosure [seedKey] leg
            keysOf rows = [ (t, o) | [_, t, o, _, _, _] <- rows ]
            dupes rows = length (keysOf rows) - Set.size (Set.fromList (keysOf rows))
        in do assertBool ("forward emitted " <> show (dupes fwd) <> " duplicate (target, ordinal) rows")
                 (dupes fwd == 0)
              assertBool ("backward emitted " <> show (dupes back) <> " duplicate (target, ordinal) rows")
                 (dupes back == 0)
    ]
  ]
