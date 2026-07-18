module DeadCodeAlgebraTest (tests) where

-- | Oracle-diff gate for the dead-code reachability PoC
-- ('PB.Analysis.DeadCodeAlgebra.deadReachAlgebraic', a 'reachFrom'-based
-- sparse closure — NOT 'star'): for every 'SouffleDeadCodeTest' fixture, run
-- BOTH Souffle's 'deadReachRules' (the hot-path IDB step) AND the algebraic
-- PoC over the SAME raw inputs, and assert the resulting @proc_dead@ sets are
-- content-exact (row-for-row, not just counts). Also re-asserts each fixture's
-- hand-verified expected dead set, so a regression in either implementation
-- fails the gate.
--
-- This is the §12 item 6 / §11-discipline gate: prove parity before any
-- production wiring. The PoC is NOT wired into 'PB.Pipeline.Passes' this
-- session (see 'PB.Analysis.DeadCodeAlgebra''s module doc).
import PB.Prelude
import PB.Pipeline.Souffle (runRuleSet)
import PB.Analysis.Rules.DeadCode
  ( initDeadReachEdbViews, deadReachRules )
import PB.Analysis.DeadCodeAlgebra (deadReachAlgebraic)
import PB.Pipeline.DuckDb
  ( withWriteConn, initSchema, withAppenderPool, ProcSummaryRow (..) )
import Database.DuckDB.Simple (query_)
import PB.Analysis.Taint qualified as Taint (ResolvedCallRow)
import SouffleDeadCodeTest
  ( ProcInfo (..), seedDeadCodeFixture, mkResolvedCall, phaseATables )

import qualified Data.Set as Set
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

-- | Convert a fixture's raw/resolved calls into the 'Taint.ResolvedCallRow'
-- list 'deadReachAlgebraic' expects — the same shape 'seedDeadCodeFixture'
-- writes into the @resolved_calls@ table (which 'initDeadReachEdbViews' reads
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
-- 'deadReachAlgebraic' expects (confidence forced to "confirmed", matching
-- 'seedDeadCodeFixture''s appendProcedures).
fixtureProcs :: [ProcInfo] -> [ProcSummaryRow]
fixtureProcs procs =
  [ ProcSummaryRow (piObject p) (piName p) (piProcType p) (piCyclomatic p) "confirmed"
  | p <- procs
  ]

-- | Oracle-diff one fixture: seed DuckDB, run Souffle 'deadReachRules', read
-- its @proc_dead@, compute the algebraic @proc_dead@ from the same raw
-- inputs, and assert (1) algebraic == Souffle (content-exact) and (2) Souffle
-- == the hand-verified expected set.
assertDeadParityAlgebraic
  :: String
  -> [ProcInfo] -> [(Text, Text, Text)] -> [(Text, Text, Text, Text)]
  -> [(Text, Text)] -> Set.Set Text
  -> Set.Set (Text, Text)
  -> TestTree
assertDeadParityAlgebraic name procs calls resolved inherits dwObjs expected =
  testCase name $ withWriteConn ":memory:" $ \conn -> do
    initSchema conn
    withAppenderPool conn phaseATables $ \pool ->
      seedDeadCodeFixture conn pool procs calls resolved inherits dwObjs
    -- Plan 175 Phase 2: initDeadReachEdbViews reads procedures/objects/
    -- resolved_calls/dw_objects eagerly — must run after the fixture is
    -- seeded, not before.
    initDeadReachEdbViews conn
    runRuleSet conn deadReachRules
    -- Souffle oracle: proc_dead materialized by deadReachRules.
    souffleRows <- query_ conn "SELECT object, proc FROM proc_dead"
                  :: IO [(Text, Text)]
    let souffleDead = Set.fromList souffleRows
    -- Algebraic PoC: same raw inputs, no Souffle.
    let algDead = deadReachAlgebraic
          (fixtureProcs procs)
          (fixtureCalls calls resolved)
          inherits
          (Set.toList dwObjs)
    -- Gate 1: algebraic == Souffle (content-exact oracle-diff).
    algDead @?= souffleDead
    -- Gate 2: Souffle still matches the hand-verified expected set.
    souffleDead @?= expected

tests :: TestTree
tests = testGroup "DeadCodeAlgebra (reachFrom PoC)"
  [ testGroup "oracle-diff vs Souffle deadReachRules (fixtures)"
    [ assertDeadParityAlgebraic "event handlers are seeds"
        [ProcInfo "obj" "ev" "event" (Just 1)] [] [] [] Set.empty Set.empty
    , assertDeadParityAlgebraic "on handlers are seeds"
        [ProcInfo "obj" "on_h" "on" (Just 1)] [] [] [] Set.empty Set.empty
    , assertDeadParityAlgebraic "unreachable function is dead"
        [ProcInfo "obj" "fn" "function" (Just 2)] [] [] [] Set.empty
        (Set.singleton ("obj", "fn"))
    , assertDeadParityAlgebraic "called function is reachable from seed"
        [ ProcInfo "obj" "ev" "event" (Just 1)
        , ProcInfo "obj" "fn_a" "function" (Just 1)
        , ProcInfo "obj" "fn_b" "function" (Just 1)
        ]
        [ ("obj", "ev", "fn_a"), ("obj", "fn_a", "fn_b") ] [] [] Set.empty Set.empty
    , assertDeadParityAlgebraic "uncalled function is dead"
        [ ProcInfo "obj" "fn_a" "function" (Just 1)
        , ProcInfo "obj" "fn_b" "function" (Just 1)
        ] [] [] [] Set.empty
        (Set.fromList [("obj", "fn_a"), ("obj", "fn_b")])
    , assertDeadParityAlgebraic "dead chain"
        [ ProcInfo "obj" "fn_c" "function" (Just 1)
        , ProcInfo "obj" "fn_d" "function" (Just 1)
        ]
        [ ("obj", "fn_c", "fn_d") ] [] [] Set.empty
        (Set.fromList [("obj", "fn_c"), ("obj", "fn_d")])
    , assertDeadParityAlgebraic "cross-object reachability"
        [ ProcInfo "obj" "ev" "event" (Just 1)
        , ProcInfo "obj2" "fn_x" "function" Nothing
        ] [] [ ("obj", "ev", "obj2", "fn_x") ] [] Set.empty Set.empty
    , assertDeadParityAlgebraic "override propagation"
        [ ProcInfo "obj_base" "base_hook" "event" Nothing
        , ProcInfo "obj_child" "base_hook" "function" Nothing
        ]
        [ ("obj_base", "base_hook", "base_hook") ] []
        [ ("obj_child", "obj_base") ] Set.empty Set.empty
    , assertDeadParityAlgebraic "DW object procedures are seeds"
        [ ProcInfo "obj_dw" "fn_a" "function" Nothing
        , ProcInfo "obj_dw" "fn_b" "function" Nothing
        ]
        [ ("obj_dw", "fn_a", "fn_b") ] [] [] (Set.singleton "obj_dw") Set.empty
    , assertDeadParityAlgebraic "confidence-medium shape: naive callers but no scoped resolution"
        [ProcInfo "obj" "fn" "function" (Just 2)]
        [ ("other_obj", "other", "fn") ] [] [] Set.empty
        (Set.singleton ("obj", "fn"))
    , assertDeadParityAlgebraic "confidence-low shape: scoped callers present"
        [ProcInfo "obj" "fn" "function" (Just 2)]
        [ ("other_obj", "other", "fn") ]
        [ ("other_obj", "other", "obj", "fn") ] [] Set.empty
        (Set.singleton ("obj", "fn"))
    , assertDeadParityAlgebraic "sorted by object then name (both dead)"
        [ ProcInfo "obj_z" "fn_b" "function" Nothing
        , ProcInfo "obj_a" "fn_a" "function" Nothing
        ] [] [] [] Set.empty
        (Set.fromList [("obj_z", "fn_b"), ("obj_a", "fn_a")])
    , assertDeadParityAlgebraic "grandchild override reachable when intermediate lacks the method"
        [ ProcInfo "gp" "hook" "event" Nothing
        , ProcInfo "child" "hook" "function" Nothing
        ] [] [] [ ("p", "gp"), ("child", "p") ] Set.empty Set.empty
    , assertDeadParityAlgebraic "same-object call reaches callee via case-insensitive name match"
        [ ProcInfo "obj" "ev" "event" (Just 1)
        , ProcInfo "obj" "fn_a" "function" (Just 1)
        ]
        [ ("obj", "ev", "FN_A") ] [] [] Set.empty Set.empty
    , assertDeadParityAlgebraic "same-object call reaches callee through a dotted (control-qualified) to_name"
        [ ProcInfo "obj" "ev" "event" (Just 1)
        , ProcInfo "obj" "fn_a" "function" (Just 1)
        ]
        [ ("obj", "ev", "dw_1.fn_a") ] [] [] Set.empty Set.empty
    ]

  , testGroup "direct golden (Souffle-independent)"
    -- Independent of the Souffle oracle: the algebraic closure's own
    -- expected proc_dead, traced by hand from the fixture shape.
    [ testCase "override propagation: child override reached via parent seed" $
        let algDead = deadReachAlgebraic
              (fixtureProcs
                [ ProcInfo "obj_base" "base_hook" "event" Nothing
                , ProcInfo "obj_child" "base_hook" "function" Nothing
                ])
              (fixtureCalls [("obj_base", "base_hook", "base_hook")] [])
              [("obj_child", "obj_base")]
              []
        in algDead @?= Set.empty
    , testCase "dead chain: both procs dead, no entry seed" $
        let algDead = deadReachAlgebraic
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
