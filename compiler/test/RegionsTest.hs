module RegionsTest (tests) where

import PB.Prelude hiding (id, (.))
import PB.AST.Expr        (Expr (..))
import PB.Compile.IR
import PB.Explain.Regions (Region (..), computeRegions, defaultComplexityThreshold)

import qualified Data.Map.Strict as Map
import Test.Tasty         (TestTree, testGroup)
import Test.Tasty.HUnit   (assertFailure, testCase, (@?=))

-- | Five sequential trivial branches (arms are pure no-ops, so each
-- contributes exactly +1 decision point), on lines 1..5 — used to exercise
-- the length-based cut policy with a small custom threshold.
fiveBranches :: Eff () ()
fiveBranches = branchEff (ExBool True) (J PId) (J PId) 5
             . branchEff (ExBool True) (J PId) (J PId) 4
             . branchEff (ExBool True) (J PId) (J PId) 3
             . branchEff (ExBool True) (J PId) (J PId) 2
             . branchEff (ExBool True) (J PId) (J PId) 1

tests :: TestTree
tests = testGroup "PB.Explain.Regions"
  [ testCase "straight-line assigns, no branches -> complexity 1" $
      let term = EAssignWithRhs "y" (ExInt "0") (ExInt "2") 2 Nothing
               . EAssignWithRhs "x" (ExInt "0") (ExInt "1") 1 Nothing :: Eff () ()
          region = computeRegions defaultComplexityThreshold (extractEffTable term)
      in regionComplexity region @?= 1

  , testCase "single EBranch -> complexity 2" $
      let term = branchEff (ExBool True)
                   (EAssignWithRhs "a" (ExInt "0") (ExInt "1") 2 Nothing)
                   (EAssignWithRhs "b" (ExInt "0") (ExInt "2") 3 Nothing) 1 :: Eff () ()
          region = computeRegions defaultComplexityThreshold (extractEffTable term)
      in regionComplexity region @?= 2

  , testCase "EBranch nested inside EBranch -> complexity 3" $
      let inner = branchEff (ExBool True)
                    (EAssignWithRhs "a" (ExInt "0") (ExInt "1") 3 Nothing)
                    (EAssignWithRhs "b" (ExInt "0") (ExInt "2") 4 Nothing) 2 :: Eff () ()
          outer = branchEff (ExBool True) inner
                    (EAssignWithRhs "c" (ExInt "0") (ExInt "3") 5 Nothing) 1 :: Eff () ()
          region = computeRegions defaultComplexityThreshold (extractEffTable outer)
      in regionComplexity region @?= 3

  , testCase "ELoop counted once statically, not per iteration" $
      let loopBody = J PInr . EAssignWithRhs "i" (ExInt "0") (ExInt "1") 2 Nothing :: Eff () (Either () ())
          term = ELoop loopBody 1 :: Eff () ()
          region = computeRegions defaultComplexityThreshold (extractEffTable term)
      in regionComplexity region @?= 2

  , testCase "region under threshold stays uncut (no children)" $
      let term = branchEff (ExBool True) (J PId) (J PId) 3
               . branchEff (ExBool True) (J PId) (J PId) 2
               . branchEff (ExBool True) (J PId) (J PId) 1 :: Eff () ()
          region = computeRegions defaultComplexityThreshold (extractEffTable term)
      in length (regionChildren region) @?= 0

  , testCase "ELetRef-backed block is always its own Region regardless of size" $
      let body = EAssignWithRhs "x" (ExInt "0") (ExInt "1") 5 Nothing :: Eff () ()
          term = ELetRef "blk1" :: Eff () ()
          effTerm = EffTerm term (Map.fromList [("blk1", body)])
          region = computeRegions defaultComplexityThreshold effTerm
      in case regionChildren region of
           [child] -> regionComplexity child @?= 1
           other   -> assertFailure ("expected exactly 1 child region, got " ++ show (length other))

  , testCase "long straight-line run above threshold gets a synthetic cut" $
      let region = computeRegions 2 (extractEffTable fiveBranches)
      in length (regionChildren region) @?= 2

  , testCase "a cut child's complexity is not double-counted into its parent" $
      let region = computeRegions 2 (extractEffTable fiveBranches)
      in regionComplexity region @?= 2

  , testCase "same EffTerm compiled twice yields identical RegionIds (determinism)" $
      let effTerm = extractEffTable fiveBranches
          r1 = computeRegions 2 effTerm
          r2 = computeRegions 2 effTerm
      in map regionId (regionChildren r1) @?= map regionId (regionChildren r2)
  ]
