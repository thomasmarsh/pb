module ClosureTest (tests) where

-- | Unit tests for 'PB.Algebra.Closure.reachFrom' — the sparse worklist
-- relaxation used for every production closure in this codebase (Plan 182
-- corpus-validation follow-up, doc/plan/182-algebraic-analysis.md Section
-- 11). Covers the adversarial shapes compiler/CLAUDE.md's Datalog Rule
-- Placement Discipline requires for any closure-shaped relation: a
-- duplicate-key/parallel-edge collision, a 0-hop/isolated-seed degenerate
-- case, and a cycle not passing through the seed.
import PB.Prelude
import PB.Algebra.Semiring (Boolean (..))
import PB.Algebra.Closure
  ( fromEdges
  , reachFrom
  , reachableSet
  )

import qualified Data.Set as Set
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests = testGroup "Closure.reachFrom"
  [ testCase "single seed, 3-chain reachability" $
      let rel = fromEdges [ (0,1,Boolean True), (1,2,Boolean True) ]
          r   = reachFrom rel [0]
      in reachableSet r 0 @?= Set.fromList [0,1,2]

  , testCase "cycle terminates and is idempotent" $
      let rel = fromEdges [ (0,1,Boolean True), (1,0,Boolean True) ]
          r   = reachFrom rel [0]
      in reachableSet r 0 @?= Set.fromList [0,1]

  , testCase "isolated seed with no outgoing edges reaches only itself" $
      -- The exact adversarial shape that broke TaintClosure.taintRelation:
      -- node 5 has no outgoing arcs at all (not even present in `rel`).
      let rel = fromEdges [ (0,1,Boolean True) ]
          r   = reachFrom rel [5]
      in reachableSet r 5 @?= Set.fromList [5]

  , testCase "two seeds give independent per-seed reachable sets" $
      -- Seed 0 reaches {0,1}; seed 10 reaches {10,11}; neither set leaks
      -- into the other's row (per-source attribution, unlike a merged
      -- multi-source union -- TaintClosure.taintConfirmed needs this).
      let rel = fromEdges [ (0,1,Boolean True), (10,11,Boolean True) ]
          r   = reachFrom rel [0, 10]
      in (reachableSet r 0, reachableSet r 10)
           @?= (Set.fromList [0,1], Set.fromList [10,11])

  , testCase "duplicate/parallel edges combine via addS" $
      let rel = fromEdges [ (0,1,Boolean True), (0,1,Boolean False) ]
          r   = reachFrom rel [0]
      in reachableSet r 0 @?= Set.fromList [0,1]

  , testCase "cycle not through the seed terminates" $
      -- 0 -> 1 -> 2 -> 1 (a cycle among 1,2, not looping back to seed 0).
      let rel = fromEdges
            [ (0,1,Boolean True), (1,2,Boolean True), (2,1,Boolean True) ]
          r   = reachFrom rel [0]
      in reachableSet r 0 @?= Set.fromList [0,1,2]

  ]
