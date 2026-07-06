module DeadCodeTest (tests) where

import PB.Prelude
import PB.Analysis.DeadCode
import PB.Analysis.Cfg  (Cfg (..), CfgBlock (..), CfgEdge (..))
import Data.Set qualified as Set
import Test.Tasty
import Test.Tasty.HUnit

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
  , testGroup "computeDeadProcedures"
    [ testCase "event handlers are seeds" $
        length (computeDeadProcedures [procEv] [] [] [] Set.empty) @?= 0
    , testCase "on handlers are seeds" $
        length (computeDeadProcedures [procOn] [] [] [] Set.empty) @?= 0
    , testCase "unreachable function is dead" $
        let dead = computeDeadProcedures [procFn] [] [] [] Set.empty
        in  length dead @?= 1
    , testCase "called function is reachable from seed" $
        let dead = computeDeadProcedures
              [procEv, procFnA, procFnB]
              [("obj", "ev", "fn_a"), ("obj", "fn_a", "fn_b")]
              [] [] Set.empty
        in  length dead @?= 0
    , testCase "uncalled function is dead" $
        let dead = computeDeadProcedures [procFnA, procFnB] [] [] [] Set.empty
        in  length dead @?= 2
    , testCase "transitive reachability" $
        let dead = computeDeadProcedures
              [procEv, procFnA, procFnB]
              [("obj", "ev", "fn_a"), ("obj", "fn_a", "fn_b")]
              [] [] Set.empty
        in  length dead @?= 0
    , testCase "dead chain" $
        let dead = computeDeadProcedures
              [procFnC, procFnD]
              [("obj", "fn_c", "fn_d")]
              [] [] Set.empty
        in  length dead @?= 2
    , testCase "cross-object reachability" $
        let dead = computeDeadProcedures
              [procEv, ProcInfo "obj2" "fn_x" "function" Nothing]
              []
              [("obj", "ev", "obj2", "fn_x")]
              [] Set.empty
        in  length dead @?= 0
    , testCase "override propagation" $
        let dead = computeDeadProcedures
              [ ProcInfo "obj_base" "base_hook" "event" Nothing
              , ProcInfo "obj_child" "base_hook" "function" Nothing
              ]
              [("obj_base", "base_hook", "base_hook")]
              []
              [("obj_child", "obj_base")]
              Set.empty
        in  length dead @?= 0
    , testCase "DW object procedures are seeds" $
        let dwFnA = ProcInfo "obj_dw" "fn_a" "function" Nothing
            dwFnB = ProcInfo "obj_dw" "fn_b" "function" Nothing
            dead = computeDeadProcedures
              [dwFnA, dwFnB]
              [("obj_dw", "fn_a", "fn_b")]
              [] [] (Set.singleton "obj_dw")
        in  length dead @?= 0
    , testCase "confidence high when no callers" $ do
        let dead = computeDeadProcedures [procFn] [] [] [] Set.empty
        case dead of
          [d] -> dpConfidence d @?= "high"
          _   -> assertFailure ("expected 1 dead proc, got " <> show (length dead))
    , testCase "confidence medium when naive callers but no scoped" $ do
        let dead = computeDeadProcedures
              [procFn]
              [("other_obj", "other", "fn")]
              [] [] Set.empty
        case dead of
          [d] -> dpConfidence d @?= "medium"
          _   -> assertFailure ("expected 1 dead proc, got " <> show (length dead))
    , testCase "confidence low when scoped callers" $ do
        let dead = computeDeadProcedures
              [procFn]
              [("other_obj", "other", "fn")]
              [("other_obj", "other", "obj", "fn")]
              [] Set.empty
        case dead of
          [d] -> dpConfidence d @?= "low"
          _   -> assertFailure ("expected 1 dead proc, got " <> show (length dead))
    , testCase "sorted by object then name" $
        let dead = computeDeadProcedures
              [ ProcInfo "obj_z" "fn_b" "function" Nothing
              , ProcInfo "obj_a" "fn_a" "function" Nothing
              ] [] [] [] Set.empty
        in  map dpObject dead @?= ["obj_a", "obj_z"]
    , testCase "grandchild override reachable when intermediate lacks the method" $
        -- gp.hook is a reachable event seed; child overrides hook but is separated from
        -- gp by an intermediate class p that does NOT define hook.
        -- With direct-children-only override edges, child.hook would be wrongly dead.
        let dead = computeDeadProcedures
              [ ProcInfo "gp"    "hook" "event"    Nothing
              , ProcInfo "child" "hook" "function" Nothing
              ]
              []
              []
              [("p", "gp"), ("child", "p")]   -- gp → p → child, p has no hook
              Set.empty
        in  length dead @?= 0
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

procEv :: ProcInfo
procEv = ProcInfo "obj" "ev" "event" (Just 1)

procOn :: ProcInfo
procOn = ProcInfo "obj" "on_h" "on" (Just 1)

procFn :: ProcInfo
procFn = ProcInfo "obj" "fn" "function" (Just 2)

procFnA :: ProcInfo
procFnA = ProcInfo "obj" "fn_a" "function" (Just 1)

procFnB :: ProcInfo
procFnB = ProcInfo "obj" "fn_b" "function" (Just 1)

procFnC :: ProcInfo
procFnC = ProcInfo "obj" "fn_c" "function" (Just 1)

procFnD :: ProcInfo
procFnD = ProcInfo "obj" "fn_d" "function" (Just 1)
