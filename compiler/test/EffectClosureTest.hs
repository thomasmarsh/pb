module EffectClosureTest (tests) where

-- | Unit tests for 'PB.Analysis.EffectClosure': the direct per-procedure
-- fold ('foldEffectClosureEff') and the transitive call-graph closure
-- ('computeProcEffectClosure'). See doc/plan/220-effect-capability-system.md
-- Layer 4 for the six closure cases this mirrors.
import PB.Prelude
import PB.AST.Expr (Expr (..))
import PB.Analysis.CallClassify (EffectTag (..))
import PB.Analysis.EffectClosure (foldEffectClosureEff, computeProcEffectClosure)
import PB.Compile.IR (Eff (..), EffTerm (..), extractEffTable, branchEff)

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests = testGroup "PB.Analysis.EffectClosure"
  [ testGroup "foldEffectClosureEff"
    [ testCase "a single ECall leaf contributes its tags" $
        foldEffectClosureEff
          (extractEffTable (ECall "f" [] 1 (Set.singleton ReadsDb) :: Eff () ()))
          @?= Set.singleton ReadsDb

    , testCase "a single ESuspend leaf contributes its tags" $
        foldEffectClosureEff
          (extractEffTable (ESuspend "retrieve:dw" [] 1 (Set.singleton Suspends) :: Eff () ()))
          @?= Set.singleton Suspends

    , testCase "EBranch unions both arms' tags" $
        foldEffectClosureEff
          (extractEffTable
            (branchEff (ExBool True)
              (ECall "f" [] 1 (Set.singleton ReadsDb))
              (ESuspend "g" [] 1 (Set.singleton WritesDb))
              1 :: Eff () ()))
          @?= Set.fromList [ReadsDb, WritesDb]

    , testCase "ELetRef resolves a shared body's tags via the table" $
        foldEffectClosureEff
          (EffTerm (ELetRef "blk")
            (Map.singleton "blk" (ECall "f" [] 1 (Set.singleton WritesUi))))
          @?= Set.singleton WritesUi
    ]

  , testGroup "computeProcEffectClosure"
    [ testCase "a direct effect with no calls closes to itself" $
        let seeds = [("o", "a", Set.singleton ReadsDb)]
            edges = []
        in Map.lookup ("o", "a") (computeProcEffectClosure seeds edges) @?= Just (Set.singleton ReadsDb)

    , testCase "a transitive effect propagates through one call" $
        let seeds = [("o", "a", Set.empty), ("o", "b", Set.singleton WritesDb)]
            edges = [("o", "a", "o", "b")]
            closure = computeProcEffectClosure seeds edges
        in do
             Map.lookup ("o", "a") closure @?= Just (Set.singleton WritesDb)
             Map.lookup ("o", "b") closure @?= Just (Set.singleton WritesDb)

    , testCase "a transitive effect propagates through a 2-hop chain" $
        let seeds = [("o", "a", Set.empty), ("o", "b", Set.empty), ("o", "c", Set.singleton Suspends)]
            edges = [("o", "a", "o", "b"), ("o", "b", "o", "c")]
            closure = computeProcEffectClosure seeds edges
        in do
             Map.lookup ("o", "a") closure @?= Just (Set.singleton Suspends)
             Map.lookup ("o", "b") closure @?= Just (Set.singleton Suspends)
             Map.lookup ("o", "c") closure @?= Just (Set.singleton Suspends)

    , testCase "an unresolved/external call contributes nothing extra, not an error" $
        let seeds = [("o", "a", Set.singleton ReadsDb)]
            edges = [("o", "a", "ext", "unknown_proc")]
        in Map.lookup ("o", "a") (computeProcEffectClosure seeds edges) @?= Just (Set.singleton ReadsDb)

    , testCase "a mutually-recursive pair of procedures each pick up the other's effects" $
        let seeds = [("o", "a", Set.singleton ReadsDb), ("o", "b", Set.singleton WritesDb)]
            edges = [("o", "a", "o", "b"), ("o", "b", "o", "a")]
            closure = computeProcEffectClosure seeds edges
            both = Set.fromList [ReadsDb, WritesDb]
        in do
             Map.lookup ("o", "a") closure @?= Just both
             Map.lookup ("o", "b") closure @?= Just both

    , testCase "a procedure with zero effects anywhere in its transitive closure is genuinely empty (pure)" $
        let seeds = [("o", "a", Set.empty), ("o", "b", Set.empty)]
            edges = [("o", "a", "o", "b")]
        in Map.lookup ("o", "a") (computeProcEffectClosure seeds edges) @?= Just Set.empty
    ]
  ]
