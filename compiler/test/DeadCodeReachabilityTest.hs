module DeadCodeReachabilityTest (tests) where

-- | Golden regression suite for 'PB.Analysis.DeadCodeReachability.deadReach'
-- (a 'PB.Algebra.Closure.reachFrom'-based sparse closure — NOT 'star'),
-- production's sole source for @proc_dead@. Each fixture's expected dead set
-- was hand-verified; 'deadReach' is the sole implementation, so the
-- assertions below are the regression contract.
import PB.Prelude
import PB.Analysis.DeadCodeReachability (deadReach)
import PB.Pipeline.DuckDb (ProcSummaryRow (..))
import PB.Analysis.Taint qualified as Taint (ResolvedCallRow)
import DeadCodeFixtures (ProcInfo (..), mkResolvedCall)

import qualified Data.Set as Set
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

-- | Convert a fixture's raw/resolved calls into the 'Taint.ResolvedCallRow'
-- list 'deadReach' expects — the same shape 'seedDeadCodeFixture'
-- writes into the @resolved_calls@ table (which 'initDeadCodeEdb' reads
-- back via 'queryResolvedCalls'). Only the columns 'callRefRows'/
-- 'resolvedCallEdgeRows'/'callsRows' actually read are set; the rest are
-- placeholders, matching 'mkResolvedCall''s contract.
fixtureCalls
  :: [(Text, Text, Text)]        -- ^ raw calls (object, from_proc, to_name)
  -> [(Text, Text, Text, Text)]  -- ^ resolved calls (object, from_proc, target_object, target_proc)
  -> [Taint.ResolvedCallRow]
fixtureCalls calls resolved =
  [ mkResolvedCall obj fromProc toName Nothing Nothing
  | (obj, fromProc, toName) <- calls
  ]
  <> [ mkResolvedCall obj fromProc (tgtObj <> "." <> tgtProc)
       (Just (tgtObj, tgtProc)) (Just 1)
     | (obj, fromProc, tgtObj, tgtProc) <- resolved
  ]

-- | Convert a fixture's 'ProcInfo' list into the 'ProcSummaryRow' list
-- 'deadReach' expects (confidence forced to "confirmed", matching
-- 'seedDeadCodeFixture''s appendProcedures).
fixtureProcs :: [ProcInfo] -> [ProcSummaryRow]
fixtureProcs procs =
  [ ProcSummaryRow (piObject p) (piName p) (piProcType p) (piCyclomatic p) "confirmed"
  | p <- procs
  ]

-- | Assert one fixture's algebraic @proc_dead@ against its hand-verified
-- expected set.
assertDeadGolden
  :: String
  -> [ProcInfo] -> [(Text, Text, Text)] -> [(Text, Text, Text, Text)]
  -> [(Text, Text)] -> Set.Set Text
  -> Set.Set (Text, Text)
  -> TestTree
assertDeadGolden name procs calls resolved inherits dwObjs expected =
  testCase name $
    deadReach
      (fixtureProcs procs)
      (fixtureCalls calls resolved)
      inherits
      (Set.toList dwObjs)
      @?= expected

tests :: TestTree
tests = testGroup "DeadCodeReachability (reachFrom, production)"
  [ testGroup "golden proc_dead sets (fixtures)"
    [ assertDeadGolden "event handlers are seeds"
        [ProcInfo "obj" "ev" "event" (Just 1)] [] [] [] Set.empty Set.empty
    , assertDeadGolden "on handlers are seeds"
        [ProcInfo "obj" "on_h" "on" (Just 1)] [] [] [] Set.empty Set.empty
    , assertDeadGolden "unreachable function is dead"
        [ProcInfo "obj" "fn" "function" (Just 2)] [] [] [] Set.empty
        (Set.singleton ("obj", "fn"))
    , assertDeadGolden "called function is reachable from seed"
        [ ProcInfo "obj" "ev" "event" (Just 1)
        , ProcInfo "obj" "fn_a" "function" (Just 1)
        , ProcInfo "obj" "fn_b" "function" (Just 1)
        ]
        [ ("obj", "ev", "fn_a"), ("obj", "fn_a", "fn_b") ] [] [] Set.empty Set.empty
    , assertDeadGolden "uncalled function is dead"
        [ ProcInfo "obj" "fn_a" "function" (Just 1)
        , ProcInfo "obj" "fn_b" "function" (Just 1)
        ] [] [] [] Set.empty
        (Set.fromList [("obj", "fn_a"), ("obj", "fn_b")])
    , assertDeadGolden "dead chain"
        [ ProcInfo "obj" "fn_c" "function" (Just 1)
        , ProcInfo "obj" "fn_d" "function" (Just 1)
        ]
        [ ("obj", "fn_c", "fn_d") ] [] [] Set.empty
        (Set.fromList [("obj", "fn_c"), ("obj", "fn_d")])
    , assertDeadGolden "cross-object reachability"
        [ ProcInfo "obj" "ev" "event" (Just 1)
        , ProcInfo "obj2" "fn_x" "function" Nothing
        ] [] [ ("obj", "ev", "obj2", "fn_x") ] [] Set.empty Set.empty
    , assertDeadGolden "override propagation"
        [ ProcInfo "obj_base" "base_hook" "event" Nothing
        , ProcInfo "obj_child" "base_hook" "function" Nothing
        ]
        [ ("obj_base", "base_hook", "base_hook") ] []
        [ ("obj_child", "obj_base") ] Set.empty Set.empty
    , assertDeadGolden "DW object procedures are seeds"
        [ ProcInfo "obj_dw" "fn_a" "function" Nothing
        , ProcInfo "obj_dw" "fn_b" "function" Nothing
        ]
        [ ("obj_dw", "fn_a", "fn_b") ] [] [] (Set.singleton "obj_dw") Set.empty
    , assertDeadGolden "confidence-medium shape: naive callers but no scoped resolution"
        [ProcInfo "obj" "fn" "function" (Just 2)]
        [ ("other_obj", "other", "fn") ] [] [] Set.empty
        (Set.singleton ("obj", "fn"))
    , assertDeadGolden "confidence-low shape: scoped callers present"
        [ProcInfo "obj" "fn" "function" (Just 2)]
        [ ("other_obj", "other", "fn") ]
        [ ("other_obj", "other", "obj", "fn") ] [] Set.empty
        (Set.singleton ("obj", "fn"))
    , assertDeadGolden "sorted by object then name (both dead)"
        [ ProcInfo "obj_z" "fn_b" "function" Nothing
        , ProcInfo "obj_a" "fn_a" "function" Nothing
        ] [] [] [] Set.empty
        (Set.fromList [("obj_z", "fn_b"), ("obj_a", "fn_a")])
    , assertDeadGolden "grandchild override reachable when intermediate lacks the method"
        [ ProcInfo "gp" "hook" "event" Nothing
        , ProcInfo "child" "hook" "function" Nothing
        ] [] [] [ ("p", "gp"), ("child", "p") ] Set.empty Set.empty
    , assertDeadGolden "same-object call reaches callee via case-insensitive name match"
        [ ProcInfo "obj" "ev" "event" (Just 1)
        , ProcInfo "obj" "fn_a" "function" (Just 1)
        ]
        [ ("obj", "ev", "FN_A") ] [] [] Set.empty Set.empty
    , assertDeadGolden "same-object call reaches callee through a dotted (control-qualified) to_name"
        [ ProcInfo "obj" "ev" "event" (Just 1)
        , ProcInfo "obj" "fn_a" "function" (Just 1)
        ]
        [ ("obj", "ev", "dw_1.fn_a") ] [] [] Set.empty Set.empty
    ]

  , testGroup "direct golden (hand-traced)"
    [ testCase "override propagation: child override reached via parent seed" $
        let algDead = deadReach
              (fixtureProcs
                [ ProcInfo "obj_base" "base_hook" "event" Nothing
                , ProcInfo "obj_child" "base_hook" "function" Nothing
                ])
              (fixtureCalls [("obj_base", "base_hook", "base_hook")] [])
              [("obj_child", "obj_base")]
              []
        in algDead @?= Set.empty
    , testCase "dead chain: both procs dead, no entry seed" $
        let algDead = deadReach
              (fixtureProcs
                [ ProcInfo "obj" "fn_c" "function" (Just 1)
                , ProcInfo "obj" "fn_d" "function" (Just 1)
                ])
              (fixtureCalls [("obj", "fn_c", "fn_d")] [])
              []
              []
        in algDead @?= Set.fromList [("obj", "fn_c"), ("obj", "fn_d")]
    ]
  ]
