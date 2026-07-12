module DeadCodeTest (tests) where

import PB.Prelude
import PB.Analysis.DeadCode
import PB.Analysis.Cfg  (Cfg (..), CfgBlock (..), CfgEdge (..), cyclomaticComplexity)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Test.Tasty
import Test.Tasty.HUnit

-- | Plan 161 Phase 2b cutover (2026-07-11): 'computeDeadProcedures' (the
-- seeded-BFS reachability computation) was deleted once its Datalog port
-- ('PB.Pipeline.Souffle.deadReachRules') was proven exact on the real
-- corpus -- see that module and 'SouffleTest.hs' for the reachability-shape
-- coverage (event/on seeds, override propagation, cross-object calls,
-- DW-object seeds, etc.) that used to live here. What remains genuinely
-- Haskell-only is 'classifyDeadProcedures': confidence/caller-count
-- classification GIVEN an already-known dead set -- report formatting, not
-- a fixpoint query.
tests :: TestTree
tests = testGroup "DeadCode"
  [ testGroup "cyclomaticComplexity"
    [ testCase "empty CFG" $
        cyclomaticComplexity emptyCfg @?= 1
    , testCase "linear chain" $
        cyclomaticComplexity linearCfg @?= 1
    , testCase "branch" $
        cyclomaticComplexity branchCfg @?= 2
    ]
  , testGroup "classifyDeadProcedures"
    [ testCase "empty dead set produces no dead procedures" $
        classifyDeadProcedures Set.empty [procFn] Map.empty Map.empty @?= []

    , testCase "a procedure in the dead set appears in the output" $
        let dead = classifyDeadProcedures (Set.singleton ("obj", "fn")) [procFn] Map.empty Map.empty
        in  map (\d -> (dpObject d, dpName d)) dead @?= [("obj", "fn")]

    , testCase "a procedure not in the dead set is excluded" $
        classifyDeadProcedures (Set.singleton ("obj", "other")) [procFn] Map.empty Map.empty @?= []

    , testCase "confidence high when no callers at all" $
        let dead = classifyDeadProcedures (Set.singleton ("obj", "fn")) [procFn] Map.empty Map.empty
        in case dead of
          [d] -> dpConfidence d @?= "high"
          _   -> assertFailure ("expected 1 dead proc, got " <> show (length dead))

    , testCase "confidence medium when naive callers but no scoped resolution" $
        let dead = classifyDeadProcedures (Set.singleton ("obj", "fn")) [procFn]
              (Map.singleton "fn" 1) Map.empty
        in case dead of
          [d] -> dpConfidence d @?= "medium"
          _   -> assertFailure ("expected 1 dead proc, got " <> show (length dead))

    , testCase "confidence low when a scoped (resolved) caller exists" $
        let dead = classifyDeadProcedures (Set.singleton ("obj", "fn")) [procFn]
              (Map.singleton "fn" 1)
              (Map.singleton ("obj", "fn") 1)
        in case dead of
          [d] -> dpConfidence d @?= "low"
          _   -> assertFailure ("expected 1 dead proc, got " <> show (length dead))

    , testCase "caller counts reflect naive and scoped tallies" $
        let dead = classifyDeadProcedures (Set.singleton ("obj", "fn")) [procFn]
              (Map.singleton "fn" 2)
              (Map.singleton ("obj", "fn") 1)
        in case dead of
          [d] -> (dpCallerCountNaive d, dpCallerCountScoped d) @?= (2, 1)
          _   -> assertFailure ("expected 1 dead proc, got " <> show (length dead))

    , testCase "cyclomatic complexity passes through unchanged" $
        let dead = classifyDeadProcedures (Set.singleton ("obj", "fn")) [procFn] Map.empty Map.empty
        in case dead of
          [d] -> dpCyclomatic d @?= Just 2
          _   -> assertFailure ("expected 1 dead proc, got " <> show (length dead))

    , testCase "dedupes overloaded procedures sharing (object, name)" $
        let overloads =
              [ ProcInfo "obj" "fn" "function" (Just 1)
              , ProcInfo "obj" "fn" "function" (Just 3)
              ]
            dead = classifyDeadProcedures (Set.singleton ("obj", "fn")) overloads Map.empty Map.empty
        in length dead @?= 1

    , testCase "sorted by object then name" $
        let dead = classifyDeadProcedures
              (Set.fromList [("obj_z", "fn_b"), ("obj_a", "fn_a")])
              [ ProcInfo "obj_z" "fn_b" "function" Nothing
              , ProcInfo "obj_a" "fn_a" "function" Nothing
              ] Map.empty Map.empty
        in map dpObject dead @?= ["obj_a", "obj_z"]
    ]
  ]

-- Test fixtures

emptyCfg :: Cfg
emptyCfg = Cfg
  { cfgEntry = "b0"
  , cfgExits = []
  , cfgBlocks = [CfgBlock "b0" [] Nothing Nothing]
  , cfgEdges = []
  }

linearCfg :: Cfg
linearCfg = Cfg
  { cfgEntry = "b0"
  , cfgExits = []
  , cfgBlocks =
      [ CfgBlock "b0" [] (Just 1) (Just 1)
      , CfgBlock "b1" [] (Just 2) (Just 2)
      ]
  , cfgEdges = [CfgEdge "b0" "b1" ""]
  }

branchCfg :: Cfg
branchCfg = Cfg
  { cfgEntry = "b0"
  , cfgExits = []
  , cfgBlocks =
      [ CfgBlock "b0" [] (Just 1) (Just 1)
      , CfgBlock "b1" [] (Just 2) (Just 2)
      , CfgBlock "b2" [] (Just 3) (Just 3)
      , CfgBlock "b3" [] (Just 4) (Just 4)
      ]
  , cfgEdges =
      [ CfgEdge "b0" "b1" "T"
      , CfgEdge "b0" "b2" "F"
      , CfgEdge "b1" "b3" ""
      , CfgEdge "b2" "b3" ""
      ]
  }

procFn :: ProcInfo
procFn = ProcInfo "obj" "fn" "function" (Just 2)
